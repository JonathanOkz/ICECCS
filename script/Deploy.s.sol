// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { CAFToken } from "../src/CAFToken.sol";
import { ReferenceERC20 } from "../src/ReferenceERC20.sol";

/// @title Deploy
/// @notice Standalone deployment of the three-contract CAF application from environment config.
/// @dev `CAFToken` creates its own `ChallengeRegistry` and `ValidatorCommittee`, so a single
///      deployment yields all three. Every parameter is validated by the constructors, so this
///      script stays thin and surfaces their precise revert reasons rather than re-checking them.
///      The broadcasting account comes from Forge's CLI flags (`--private-key`, `--account`, or
///      `--ledger`); no key is read from the environment.
contract Deploy is Script {
    function run() external returns (CAFToken token, ReferenceERC20 referenceToken) {
        // Token metadata and the account credited with the entire initial supply.
        string memory name = vm.envOr("CAF_NAME", string("Challenge-Aware Token"));
        string memory symbol = vm.envOr("CAF_SYMBOL", string("CAF"));
        address initialHolder = vm.envAddress("CAF_INITIAL_HOLDER");
        uint256 initialSupply = vm.envUint("CAF_INITIAL_SUPPLY");

        // Immutable membership sets and the supermajority quorum (3*quorum > 2*validators).
        address[] memory challengers = vm.envAddress("CAF_CHALLENGERS", ",");
        address[] memory validators = vm.envAddress("CAF_VALIDATORS", ",");
        uint256 quorum = vm.envUint("CAF_QUORUM");

        vm.startBroadcast();
        token = new CAFToken(
            name,
            symbol,
            initialHolder,
            initialSupply,
            _window("CAF_CHALLENGE_WINDOW"),
            _window("CAF_REVIEW_WINDOW"),
            challengers,
            validators,
            quorum
        );
        // Optional plain-ERC-20 baseline for the gas comparison; off unless explicitly requested.
        if (vm.envOr("CAF_DEPLOY_REFERENCE", false)) {
            referenceToken = new ReferenceERC20(initialHolder, initialSupply);
        }
        vm.stopBroadcast();

        console2.log("CAFToken:          ", address(token));
        console2.log("ChallengeRegistry: ", address(token.challengeRegistry()));
        console2.log("ValidatorCommittee:", address(token.validatorCommittee()));
        if (address(referenceToken) != address(0)) {
            console2.log("ReferenceERC20:    ", address(referenceToken));
        }
    }

    /// @dev Reads a window in seconds and narrows it to uint64; the constructor further rejects
    ///      zero and anything above 3650 days.
    function _window(string memory key) private view returns (uint64) {
        uint256 secondsValue = vm.envUint(key);
        require(secondsValue <= type(uint64).max, "window exceeds uint64");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(secondsValue);
    }
}
