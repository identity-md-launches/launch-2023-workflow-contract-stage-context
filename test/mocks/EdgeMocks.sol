// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./Mocks.sol";

interface IPayTarget {
    function pay(bytes32 orderId, address token) external returns (uint256);
}

/// @dev `decimals()` returns an arbitrary raw payload chosen by the test (wrong length, too large, ...).
contract RawDecimalsToken {
    bytes private _payload;
    bool private _revertOnDecimals;

    function setDecimalsPayload(bytes calldata payload) external {
        _payload = payload;
    }

    function setRevertOnDecimals(bool v) external {
        _revertOnDecimals = v;
    }

    // Not declared with a return type on purpose: the raw payload is returned as-is.
    fallback(bytes calldata) external returns (bytes memory) {
        if (msg.sig == bytes4(keccak256("decimals()"))) {
            if (_revertOnDecimals) revert("decimals reverted");
            return _payload;
        }
        revert("unknown selector");
    }
}

/// @dev Moves tokens but returns an arbitrary raw payload from `transferFrom` (short data, 64 bytes, ...).
contract RawReturnERC20 {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bytes private _payload;

    function setTransferPayload(bytes calldata payload) external {
        _payload = payload;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // Raw transferFrom: executes the move, then returns the configured payload verbatim.
    fallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sig == bytes4(keccak256("transferFrom(address,address,uint256)")), "unknown selector");
        (address from, address to, uint256 amount) = abi.decode(data[4:], (address, address, uint256));
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return _payload;
    }
}

/// @dev Reverts with a reason string from `transferFrom`.
contract RevertingERC20 is MockERC20 {
    constructor() MockERC20(18) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("transfer blocked");
    }
}

/// @dev Charges a fee on every transferFrom: the recipient receives less than `amount`.
contract FeeOnTransferERC20 is MockERC20 {
    uint256 public constant FEE_BPS = 100; // 1%

    constructor() MockERC20(18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        uint256 fee = (amount * FEE_BPS) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        return true;
    }
}

/// @dev Re-enters `pay` on the N-th transferFrom call (1-based), so both the swarm and the treasury
/// transfer can be used as the re-entry point.
contract CountingReentrantERC20 is MockERC20 {
    address public target;
    uint256 public attackOnCall;
    uint256 public calls;
    bool public attacked;
    bytes public lastRevert;

    constructor() MockERC20(18) {}

    function configure(address target_, uint256 attackOnCall_) external {
        target = target_;
        attackOnCall = attackOnCall_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        calls += 1;
        if (!attacked && target != address(0) && calls == attackOnCall) {
            attacked = true;
            try IPayTarget(target).pay(keccak256("reenter-2"), address(this)) {}
            catch (bytes memory reason) {
                lastRevert = reason;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Identity NFT whose balanceOf reverts.
contract RevertingERC721 {
    function balanceOf(address) external pure returns (uint256) {
        revert("nft down");
    }
}

/// @dev Identity NFT whose balanceOf tries to re-enter `pay` (must fail: it is reached by STATICCALL).
contract ReentrantERC721 {
    address public target;

    function setTarget(address target_) external {
        target = target_;
    }

    function balanceOf(address) external returns (uint256) {
        IPayTarget(target).pay(keccak256("nft-reenter"), address(0));
        return 1;
    }
}

/// @dev Contract that has no balanceOf at all (set as identity NFT by mistake).
contract NotAnNft {
    function ping() external pure returns (bool) {
        return true;
    }
}

/// @dev A payer that is a contract.
contract ContractPayer {
    function approveAndPay(address token, address payments, uint256 amount, bytes32 orderId)
        external
        returns (uint256)
    {
        MockERC20(token).approve(payments, amount);
        return IPayTarget(payments).pay(orderId, token);
    }
}
