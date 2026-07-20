// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ChallengeRegistry
/// @notice Immutable challenger membership and tamper-evident evidence commitments for CAF.
/// @dev CAFToken is the only writer. Off-chain tooling is responsible for resolving an IPFS CID
///      and checking that its SHA-256 digest equals evidenceHash.
contract ChallengeRegistry {
    // Challenger metadata shares one slot; the evidence commitment occupies the other.
    struct ChallengeRecord {
        address challenger;
        uint64 recordedAt;
        bool preConfirmation;
        bytes32 evidenceHash;
    }

    address private immutable _cafToken;

    mapping(address => bool) public isAuthorizedChallenger;
    mapping(bytes32 => ChallengeRecord) public challenges;

    event ChallengeRecorded(
        bytes32 indexed transferId,
        address indexed challenger,
        bytes32 indexed evidenceHash,
        bool preConfirmation,
        uint64 recordedAt
    );

    error Unauthorized();
    error ZeroAddress();
    error EmptyTransferId();
    error EmptyEvidenceHash();
    error EmptyChallengerSet();
    error DuplicateChallenger(address challenger);
    error ChallengeAlreadyExists(bytes32 transferId);
    error ChallengeNotFound(bytes32 transferId);

    constructor(address[] memory challengers_) {
        if (challengers_.length == 0) revert EmptyChallengerSet();

        _cafToken = msg.sender;
        for (uint256 i = 0; i < challengers_.length; ++i) {
            address challenger = challengers_[i];
            if (challenger == address(0)) revert ZeroAddress();
            if (isAuthorizedChallenger[challenger]) revert DuplicateChallenger(challenger);
            isAuthorizedChallenger[challenger] = true;
        }
    }

    function recordChallenge(
        bytes32 transferId,
        address challenger,
        bytes32 evidenceHash,
        bool preConfirmation
    ) external {
        if (msg.sender != _cafToken) revert Unauthorized();
        if (transferId == bytes32(0)) revert EmptyTransferId();
        if (evidenceHash == bytes32(0)) revert EmptyEvidenceHash();
        if (!isAuthorizedChallenger[challenger]) revert Unauthorized();
        if (challenges[transferId].challenger != address(0)) {
            revert ChallengeAlreadyExists(transferId);
        }

        uint64 recordedAt = uint64(block.timestamp);
        challenges[transferId] = ChallengeRecord({
            challenger: challenger,
            recordedAt: recordedAt,
            preConfirmation: preConfirmation,
            evidenceHash: evidenceHash
        });
        emit ChallengeRecorded(transferId, challenger, evidenceHash, preConfirmation, recordedAt);
    }

    function isPreChallenge(bytes32 transferId) external view returns (bool) {
        return challenges[transferId].preConfirmation;
    }

    function challengerOf(bytes32 transferId) external view returns (address challenger) {
        challenger = challenges[transferId].challenger;
        if (challenger == address(0)) revert ChallengeNotFound(transferId);
    }
}
