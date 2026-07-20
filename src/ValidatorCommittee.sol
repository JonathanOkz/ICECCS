// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ValidatorCommittee
/// @notice Fixed-membership committee with a deployment-time supermajority threshold.
contract ValidatorCommittee {
    enum Decision {
        None,
        Accept,
        Reject
    }

    // The proof occupies slot 0; every remaining field packs into slot 1.
    struct Ballot {
        bytes32 proofHash;
        address recoveryAddress;
        uint64 deadline;
        uint16 acceptVotes;
        uint16 rejectVotes;
    }

    address private immutable _cafToken;

    uint256 public immutable validatorCount;
    uint256 public immutable quorum;

    mapping(address => bool) public isValidator;
    mapping(bytes32 => Ballot) public ballots;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;

    event BallotOpened(
        bytes32 indexed transferId,
        bytes32 indexed proofHash,
        address indexed recoveryAddress,
        uint64 deadline
    );
    event ProofVoteCast(bytes32 indexed transferId, address indexed validator, bool accept);
    event QuorumReached(bytes32 indexed transferId, Decision decision);

    error Unauthorized();
    error ZeroAddress();
    error EmptyValidatorSet();
    error InvalidQuorum(uint256 validatorCount, uint256 quorum);
    error DuplicateValidator(address validator);
    error EmptyProofHash();
    error InvalidDeadline();
    error BallotAlreadyExists(bytes32 transferId);
    error BallotNotFound(bytes32 transferId);
    error VotingClosed(bytes32 transferId);
    error AlreadyVoted(bytes32 transferId, address validator);

    constructor(address[] memory validators_, uint256 quorum_) {
        uint256 count = validators_.length;
        if (count == 0) revert EmptyValidatorSet();
        // uint16 vote counters cannot overflow: EIP-3860 bounds the set far below 2^16.
        if (quorum_ == 0 || quorum_ > count || quorum_ * 3 <= count * 2) {
            revert InvalidQuorum(count, quorum_);
        }

        _cafToken = msg.sender;
        validatorCount = count;
        quorum = quorum_;

        for (uint256 i = 0; i < count; ++i) {
            address validator = validators_[i];
            if (validator == address(0)) revert ZeroAddress();
            if (isValidator[validator]) revert DuplicateValidator(validator);
            isValidator[validator] = true;
        }
    }

    function openBallot(
        bytes32 transferId,
        bytes32 proofHash,
        address recoveryAddress,
        uint64 deadline
    ) external {
        if (msg.sender != _cafToken) revert Unauthorized();
        if (proofHash == bytes32(0)) revert EmptyProofHash();
        if (recoveryAddress == address(0)) revert ZeroAddress();
        if (deadline <= block.timestamp) revert InvalidDeadline();
        Ballot storage ballot = ballots[transferId];
        if (ballot.proofHash != bytes32(0)) revert BallotAlreadyExists(transferId);
        // Vote counters stay at their zero defaults until validators participate.
        ballot.proofHash = proofHash;
        ballot.recoveryAddress = recoveryAddress;
        ballot.deadline = deadline;
        emit BallotOpened(transferId, proofHash, recoveryAddress, deadline);
    }

    function voteOnProof(bytes32 transferId, bool accept) external {
        if (!isValidator[msg.sender]) revert Unauthorized();

        Ballot storage ballot = ballots[transferId];
        if (ballot.proofHash == bytes32(0)) revert BallotNotFound(transferId);
        if (_decisionOf(ballot) != Decision.None || block.timestamp >= ballot.deadline) {
            revert VotingClosed(transferId);
        }
        if (hasVoted[transferId][msg.sender]) {
            revert AlreadyVoted(transferId, msg.sender);
        }

        hasVoted[transferId][msg.sender] = true;
        uint256 votes;
        if (accept) {
            votes = ++ballot.acceptVotes;
        } else {
            votes = ++ballot.rejectVotes;
        }

        emit ProofVoteCast(transferId, msg.sender, accept);
        if (votes >= quorum) {
            emit QuorumReached(transferId, accept ? Decision.Accept : Decision.Reject);
        }
    }

    function resolutionOf(bytes32 transferId)
        external
        view
        returns (Decision decision, address recoveryAddress)
    {
        Ballot storage ballot = ballots[transferId];
        return (_decisionOf(ballot), ballot.recoveryAddress);
    }

    function _decisionOf(Ballot storage ballot) private view returns (Decision) {
        if (ballot.acceptVotes >= quorum) return Decision.Accept;
        if (ballot.rejectVotes >= quorum) return Decision.Reject;
        return Decision.None;
    }
}
