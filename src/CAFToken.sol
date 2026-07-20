// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { DoubleEndedQueue } from "@openzeppelin/contracts/utils/structs/DoubleEndedQueue.sol";
import { ChallengeRegistry } from "./ChallengeRegistry.sol";
import { ValidatorCommittee } from "./ValidatorCommittee.sol";

/// @title CAFToken
/// @notice Direct ERC-20 application-layer implementation of Challenge-Aware Finality.
/// @dev Positive transfers create LIFO attribution lots. Challenged value is held by this contract
///      as real ERC-20 escrow and is absent from the challenged recipient's balance.
contract CAFToken is ERC20 {
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;

    enum TransferState {
        Pending,
        Valid,
        Challenged,
        Released,
        Recovered
    }

    // Transfer data occupies four contiguous slots.
    struct TransferRecord {
        address sender;
        uint64 challengeDeadline;
        address recipient;
        uint64 reviewDeadline;
        TransferState state;
        uint256 amount;
        /// @dev Valid: attributable balance. Challenged: escrowed balance. Terminal: zero.
        uint256 activeAmount;
    }

    // Distinct keccak domains keep caller-salted intent ids and nonce-based standard ids apart.
    uint8 private constant INTENT_ID_DOMAIN = 1;
    uint8 private constant STANDARD_ID_DOMAIN = 2;

    // Bounding windows at deployment keeps every uint64 deadline addition overflow-free.
    uint64 private constant MAX_WINDOW = 3650 days;

    ChallengeRegistry public immutable challengeRegistry;
    ValidatorCommittee public immutable validatorCommittee;
    uint64 public immutable challengeWindow;
    uint64 public immutable reviewWindow;

    mapping(bytes32 => TransferRecord) private _transfers;
    /// @dev Per-account LIFO attribution lots, newest at the back.
    mapping(address => DoubleEndedQueue.Bytes32Deque) private _lots;
    mapping(address => uint256) private _standardTransferNonces;

    uint256 public totalEscrowed;

    event TransferSubmitted(
        bytes32 indexed transferId,
        address indexed sender,
        address indexed recipient,
        uint256 amount
    );
    event TransferChallenged(
        bytes32 indexed transferId,
        address indexed challenger,
        uint256 amount,
        bool preConfirmation,
        uint64 reviewDeadline
    );
    event FundsRecovered(
        bytes32 indexed transferId, address indexed recoveryAddress, uint256 amount
    );
    event FundsReleased(bytes32 indexed transferId, address indexed recipient, uint256 amount);

    error ZeroAddress();
    error ZeroTransferAmount();
    error InvalidChallengeWindow();
    error InvalidReviewWindow();
    error TransferNotFound(bytes32 transferId);
    error TransferIdAlreadyUsed(bytes32 transferId);
    error InvalidTransferState(bytes32 transferId, TransferState expected, TransferState actual);
    error ChallengeWindowClosed(bytes32 transferId);
    error NotChallengeOriginator(address caller);
    error InvalidRecoveryAddress();
    error NoAttributableBalance(bytes32 transferId);
    error AcceptanceQuorumNotReached(bytes32 transferId);
    error ReleaseConditionNotMet(bytes32 transferId);
    error AcceptedProofMustRecover(bytes32 transferId);
    error PreChallengedStandardTransfer(bytes32 transferId);

    constructor(
        string memory name_,
        string memory symbol_,
        address initialHolder_,
        uint256 initialSupply_,
        uint64 challengeWindow_,
        uint64 reviewWindow_,
        address[] memory challengers_,
        address[] memory validators_,
        uint256 quorum_
    ) ERC20(name_, symbol_) {
        if (initialHolder_ == address(0)) revert ZeroAddress();
        if (challengeWindow_ == 0 || challengeWindow_ > MAX_WINDOW) {
            revert InvalidChallengeWindow();
        }
        if (reviewWindow_ == 0 || reviewWindow_ > MAX_WINDOW) revert InvalidReviewWindow();

        challengeWindow = challengeWindow_;
        reviewWindow = reviewWindow_;
        challengeRegistry = new ChallengeRegistry(challengers_);
        validatorCommittee = new ValidatorCommittee(validators_, quorum_);
        _mint(initialHolder_, initialSupply_);
    }

    /// @notice Submits a positive CAF transfer with a caller-chosen intent salt.
    function submitTransfer(address recipient, uint256 amount, bytes32 salt)
        external
        returns (bytes32 transferId)
    {
        if (amount == 0) revert ZeroTransferAmount();
        transferId = computeTransferId(msg.sender, recipient, amount, salt);
        _submitTransfer(msg.sender, recipient, amount, transferId, true);
    }

    /// @notice Standard ERC-20 entry point routed through the CAF state machine.
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        return _cafTransfer(msg.sender, recipient, amount);
    }

    /// @notice Delegated ERC-20 entry point routed through the same CAF state machine.
    function transferFrom(address sender, address recipient, uint256 amount)
        public
        override
        returns (bool)
    {
        _spendAllowance(sender, msg.sender, amount);
        return _cafTransfer(sender, recipient, amount);
    }

    /// @dev Standard entry points keep strict ERC-20 semantics: true always means the recipient
    ///      was credited, so a pre-challenged standard id reverts instead of escrowing.
    function _cafTransfer(address sender, address recipient, uint256 amount)
        private
        returns (bool)
    {
        if (amount == 0) {
            _transfer(sender, recipient, 0);
            return true;
        }
        uint256 nonce = _standardTransferNonces[sender]++;
        _submitTransfer(
            sender,
            recipient,
            amount,
            _computeStandardTransferId(sender, recipient, amount, nonce),
            false
        );
        return true;
    }

    /// @notice Registers a pre-challenge for an unknown id or challenges a live Valid transfer.
    function challengeTransfer(bytes32 transferId, bytes32 evidenceHash) external {
        TransferRecord storage record = _transfers[transferId];
        if (record.sender == address(0)) {
            challengeRegistry.recordChallenge(transferId, msg.sender, evidenceHash, true);
            return;
        }

        if (record.state != TransferState.Valid) {
            revert InvalidTransferState(transferId, TransferState.Valid, record.state);
        }
        if (block.timestamp >= record.challengeDeadline) {
            revert ChallengeWindowClosed(transferId);
        }

        uint256 attributable = record.activeAmount;
        if (attributable == 0) revert NoAttributableBalance(transferId);

        challengeRegistry.recordChallenge(transferId, msg.sender, evidenceHash, false);
        _transfer(record.recipient, address(this), attributable);
        _enterChallengedState(transferId, record, attributable, false, msg.sender);
    }

    /// @notice Opens the one ballot for a challenged transfer. The challenge originator holds an
    ///         exclusive half of the review window; thereafter any authorised challenger may call,
    ///         so a silent originator cannot capture the challenge until expiry.
    function submitProof(bytes32 transferId, bytes32 proofHash, address recoveryAddress) external {
        TransferRecord storage record = _recordInState(transferId, TransferState.Challenged);
        if (msg.sender != challengeRegistry.challengerOf(transferId)) {
            bool fallbackOpen = block.timestamp >= record.reviewDeadline - reviewWindow / 2;
            if (!fallbackOpen || !challengeRegistry.isAuthorizedChallenger(msg.sender)) {
                revert NotChallengeOriginator(msg.sender);
            }
        }
        // A self-transfer would clear escrow accounting without moving the locked tokens.
        if (recoveryAddress == address(this)) revert InvalidRecoveryAddress();
        validatorCommittee.openBallot(transferId, proofHash, recoveryAddress, record.reviewDeadline);
    }

    /// @notice Executes an acceptance decision and transfers escrow to the proof address.
    function recoverFunds(bytes32 transferId) external {
        TransferRecord storage record = _recordInState(transferId, TransferState.Challenged);
        (ValidatorCommittee.Decision decision, address recoveryAddress) =
            validatorCommittee.resolutionOf(transferId);
        if (decision != ValidatorCommittee.Decision.Accept) {
            revert AcceptanceQuorumNotReached(transferId);
        }

        uint256 amount = _takeEscrow(transferId, record);
        record.state = TransferState.Recovered;
        _transfer(address(this), recoveryAddress, amount);
        emit FundsRecovered(transferId, recoveryAddress, amount);
    }

    /// @notice Executes a rejection decision or review-window expiry.
    function releaseFunds(bytes32 transferId) external {
        TransferRecord storage record = _recordInState(transferId, TransferState.Challenged);
        (ValidatorCommittee.Decision decision,) = validatorCommittee.resolutionOf(transferId);
        if (decision == ValidatorCommittee.Decision.Accept) {
            revert AcceptedProofMustRecover(transferId);
        }

        bool rejected = decision == ValidatorCommittee.Decision.Reject;
        bool expired = block.timestamp >= record.reviewDeadline;
        if (!rejected && !expired) revert ReleaseConditionNotMet(transferId);

        uint256 amount = _takeEscrow(transferId, record);
        record.state = TransferState.Released;
        _transfer(address(this), record.recipient, amount);
        emit FundsReleased(transferId, record.recipient, amount);
    }

    function computeTransferId(address sender, address recipient, uint256 amount, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                INTENT_ID_DOMAIN, block.chainid, address(this), sender, recipient, amount, salt
            )
        );
    }

    function previewStandardTransferId(address sender, address recipient, uint256 amount)
        external
        view
        returns (bytes32)
    {
        return _computeStandardTransferId(
            sender, recipient, amount, _standardTransferNonces[sender]
        );
    }

    function stateOf(bytes32 transferId) external view returns (TransferState) {
        return _existingRecord(transferId).state;
    }

    function senderOf(bytes32 transferId) external view returns (address) {
        return _existingRecord(transferId).sender;
    }

    function recipientOf(bytes32 transferId) external view returns (address) {
        return _existingRecord(transferId).recipient;
    }

    function challengeDeadlineOf(bytes32 transferId) external view returns (uint64) {
        return _existingRecord(transferId).challengeDeadline;
    }

    function reviewDeadlineOf(bytes32 transferId) external view returns (uint64) {
        return _existingRecord(transferId).reviewDeadline;
    }

    function remainingAttributableAmountOf(bytes32 transferId) external view returns (uint256) {
        TransferRecord storage record = _existingRecord(transferId);
        if (record.state != TransferState.Valid || block.timestamp >= record.challengeDeadline) {
            return 0;
        }
        return record.activeAmount;
    }

    /// @notice Returns the amount currently held in escrow for a challenged transfer.
    function lockedAmountOf(bytes32 transferId) external view returns (uint256) {
        TransferRecord storage record = _existingRecord(transferId);
        return record.state == TransferState.Challenged ? record.activeAmount : 0;
    }

    function _submitTransfer(
        address sender,
        address recipient,
        uint256 amount,
        bytes32 transferId,
        bool interceptable
    ) private {
        if (sender == address(0) || recipient == address(0)) {
            revert ZeroAddress();
        }
        TransferRecord storage record = _transfers[transferId];
        if (record.sender != address(0)) revert TransferIdAlreadyUsed(transferId);
        bool preChallenged = challengeRegistry.isPreChallenge(transferId);
        if (preChallenged && !interceptable) revert PreChallengedStandardTransfer(transferId);

        record.sender = sender;
        record.recipient = recipient;
        record.amount = amount;

        _consumeAttribution(sender, amount);
        emit TransferSubmitted(transferId, sender, recipient, amount);

        if (preChallenged) {
            _transfer(sender, address(this), amount);
            _enterChallengedState(
                transferId, record, amount, true, challengeRegistry.challengerOf(transferId)
            );
            return;
        }

        _transfer(sender, recipient, amount);
        record.state = TransferState.Valid;
        record.activeAmount = amount;
        record.challengeDeadline = uint64(block.timestamp) + challengeWindow;
        _lots[recipient].pushBack(transferId);
    }

    function _enterChallengedState(
        bytes32 transferId,
        TransferRecord storage record,
        uint256 amount,
        bool preConfirmation,
        address challenger
    ) private {
        uint64 reviewDeadline = uint64(block.timestamp) + reviewWindow;
        record.reviewDeadline = reviewDeadline;
        record.state = TransferState.Challenged;
        record.activeAmount = amount;
        totalEscrowed += amount;
        emit TransferChallenged(transferId, challenger, amount, preConfirmation, reviewDeadline);
    }

    /// @dev Implements paper balance_for(id); the LIFO walk is unbounded to preserve atomicity.
    function _consumeAttribution(address account, uint256 amount) private {
        DoubleEndedQueue.Bytes32Deque storage lots = _lots[account];
        uint256 remaining = amount;

        while (!lots.empty() && remaining != 0) {
            TransferRecord storage record = _transfers[lots.back()];

            // Deadlines are monotonic in this append-only queue, so every older lot is expired too.
            if (block.timestamp >= record.challengeDeadline) {
                lots.clear();
                return;
            }

            uint256 attributable = record.activeAmount;
            // Challenged records may still hold escrow in activeAmount; only dequeue them here.
            if (record.state != TransferState.Valid || attributable == 0) {
                lots.popBack();
                continue;
            }

            uint256 spent = remaining < attributable ? remaining : attributable;
            record.activeAmount = attributable - spent;
            remaining -= spent;
            if (spent == attributable) lots.popBack();
        }
    }

    function _takeEscrow(bytes32 transferId, TransferRecord storage record)
        private
        returns (uint256 amount)
    {
        amount = record.activeAmount;
        if (amount == 0) revert NoAttributableBalance(transferId);
        record.activeAmount = 0;
        totalEscrowed -= amount;
    }

    function _computeStandardTransferId(
        address sender,
        address recipient,
        uint256 amount,
        uint256 nonce
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                STANDARD_ID_DOMAIN, block.chainid, address(this), sender, recipient, amount, nonce
            )
        );
    }

    function _recordInState(bytes32 transferId, TransferState expected)
        private
        view
        returns (TransferRecord storage record)
    {
        record = _existingRecord(transferId);
        if (record.state != expected) {
            revert InvalidTransferState(transferId, expected, record.state);
        }
    }

    function _existingRecord(bytes32 transferId)
        private
        view
        returns (TransferRecord storage record)
    {
        record = _transfers[transferId];
        if (record.sender == address(0)) revert TransferNotFound(transferId);
    }
}
