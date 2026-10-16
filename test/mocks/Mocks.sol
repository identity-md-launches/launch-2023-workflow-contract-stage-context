// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Plain test ERC-20 with configurable decimals and a public mint.
contract MockERC20 {
    string public name = "Test Token";
    string public symbol = "TST";
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Returns false instead of reverting.
contract FalseReturningERC20 is MockERC20 {
    constructor() MockERC20(18) {}

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// @dev Moves tokens but returns nothing (USDT-style).
contract NoReturnERC20 {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Has no decimals() function.
contract NoDecimalsToken {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

interface IPayable {
    function pay(bytes32 orderId, address token) external returns (uint256);
}

/// @dev Re-enters `pay` from inside transferFrom.
contract ReentrantERC20 is MockERC20 {
    address public target;
    bool public attacked;
    bytes public lastRevert;

    constructor() MockERC20(18) {}

    function setTarget(address target_) external {
        target = target_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!attacked && target != address(0)) {
            attacked = true;
            try IPayable(target).pay(keccak256("reenter"), address(this)) {}
            catch (bytes memory reason) {
                lastRevert = reason;
            }
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Minimal test ERC-721 balance surface.
contract MockERC721 {
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        require(ownerOf[id] == address(0), "minted");
        ownerOf[id] = to;
        balanceOf[to] += 1;
    }

    function burn(uint256 id) external {
        address holder = ownerOf[id];
        require(holder != address(0), "not minted");
        delete ownerOf[id];
        balanceOf[holder] -= 1;
    }
}
