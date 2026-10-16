// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FolirPayments} from "../src/FolirPayments.sol";

/// @dev Stands in for the launch factory: deploys init code with CREATE2 and zero value.
contract FactoryStandIn {
    function deploy(bytes memory code, bytes32 salt) external returns (address created) {
        assembly ("memory-safe") {
            created := create2(0, add(code, 32), mload(code), salt)
        }
        require(created != address(0) && created.code.length > 0, "constructor failed");
    }
}

/// @notice Rehearses the launch: constructor on an empty chain, owner is the argument, runtime is bounded
/// and contains no DELEGATECALL, CALLCODE or SELFDESTRUCT.
contract DeploymentTest is Test {
    address internal constant LAUNCH_OWNER = 0xd470133A27B58a2949D2a0BE9414204dB3eb0aB4;

    function test_deployViaFactory_ownerIsLaunchOwnerNotFactory() public {
        FactoryStandIn factory = new FactoryStandIn();
        bytes memory code = abi.encodePacked(type(FolirPayments).creationCode, abi.encode(LAUNCH_OWNER));
        bytes32 salt = keccak256("folir");
        address predicted = vm.computeCreate2Address(salt, keccak256(code), address(factory));

        address created = factory.deploy(code, salt);
        assertEq(created, predicted);

        FolirPayments p = FolirPayments(created);
        assertEq(p.owner(), LAUNCH_OWNER);
        assertTrue(p.owner() != address(factory));
        assertTrue(p.owner() != tx.origin);
        assertTrue(p.paused());
        assertEq(p.pendingOwner(), address(0));
    }

    function test_runtime_boundedAndNoForbiddenOpcodes() public {
        FolirPayments p = new FolirPayments(LAUNCH_OWNER);
        bytes memory code = address(p).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
