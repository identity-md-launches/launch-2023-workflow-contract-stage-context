// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal ERC-20 surface used by FolirPayments.
interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @dev Minimal ERC-721 surface used by FolirPayments.
interface IERC721Minimal {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title FolirPayments
/// @notice Payment-receipt contract for the FOLIR test release on Sepolia.
///
/// A payer pays in the single allowlisted test ERC-20 token and receives an on-chain receipt keyed by
/// (payer, orderId). Each (payer, orderId) pair can be paid at most once.
///
/// Pricing, in whole units of the payment token (10 ** decimals):
///   - standard:              0.75 = 0.50 to the swarm-funding recipient + 0.25 to the treasury recipient
///   - identity NFT holder:   0.50 = 0.50 to the swarm-funding recipient, no treasury transfer
///
/// Tokens move directly from the payer to the recipients with `transferFrom`; this contract never holds
/// funds. The contract starts paused and can only be unpaused once the payment token, both recipients and
/// the identity NFT are configured by the owner.
contract FolirPayments {
    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Swarm-funding share, in hundredths of a token unit (0.50).
    uint256 public constant SWARM_SHARE_CENTS = 50;
    /// @notice Treasury share for standard payers, in hundredths of a token unit (0.25).
    uint256 public constant TREASURY_SHARE_CENTS = 25;
    /// @notice Smallest accepted payment-token decimals (0.25 units must be representable).
    uint8 public constant MIN_TOKEN_DECIMALS = 2;
    /// @notice Largest accepted payment-token decimals.
    uint8 public constant MAX_TOKEN_DECIMALS = 36;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    struct Receipt {
        uint256 number; // 1-based sequential receipt number; 0 means "no receipt"
        address payer;
        bytes32 orderId;
        address token;
        uint256 swarmAmount;
        uint256 treasuryAmount;
        address swarmRecipient;
        address treasuryRecipient;
        bool identityDiscount;
        uint64 paidAt;
    }

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    address public owner;
    address public pendingOwner;
    bool public paused;

    address public paymentToken;
    uint8 public paymentTokenDecimals;
    address public swarmRecipient;
    address public treasuryRecipient;
    address public identityNft;

    uint256 public receiptCount;
    mapping(bytes32 receiptKey => Receipt) private _receipts;
    mapping(uint256 number => bytes32 receiptKey) public receiptKeyByNumber;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event PaymentTokenSet(address indexed previousToken, address indexed newToken, uint8 decimals);
    event SwarmRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event TreasuryRecipientSet(address indexed previousRecipient, address indexed newRecipient);
    event IdentityNftSet(address indexed previousNft, address indexed newNft);
    event PaymentReceived(
        uint256 indexed number,
        address indexed payer,
        bytes32 indexed orderId,
        address token,
        uint256 swarmAmount,
        uint256 treasuryAmount,
        bool identityDiscount
    );

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error IsPaused();
    error NotPaused();
    error PaymentTokenNotConfigured();
    error SwarmRecipientNotConfigured();
    error TreasuryRecipientNotConfigured();
    error IdentityNftNotConfigured();
    error RecipientsMustDiffer();
    error NotAContract(address account);
    error UnsupportedTokenDecimals(uint8 decimals);
    error TokenDecimalsUnavailable(address token);
    error TokenNotAllowlisted(address token);
    error ReceiptAlreadyExists(address payer, bytes32 orderId);
    error ZeroOrderId();
    error TokenTransferFailed(address token, address from, address to, uint256 amount);
    error Reentrancy();

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param owner_ The launch owner (manifest `$owner`). Never the deploying factory.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        paused = true;
        emit OwnershipTransferred(address(0), owner_);
        emit Paused(owner_);
    }

    // ---------------------------------------------------------------------------------------------
    // Payment
    // ---------------------------------------------------------------------------------------------

    /// @notice Pays for `orderId` with the allowlisted payment token and records a receipt.
    /// @dev The payer must first approve this contract for at least the amount returned by `quote`.
    /// @param orderId Caller-chosen, non-zero order identifier; each (payer, orderId) can be paid once.
    /// @param token The token the payer expects to pay with; must equal the allowlisted `paymentToken`.
    /// @return number The sequential receipt number.
    function pay(bytes32 orderId, address token) external nonReentrant returns (uint256 number) {
        if (paused) revert IsPaused();
        if (orderId == bytes32(0)) revert ZeroOrderId();
        address allowed = paymentToken;
        if (token != allowed) revert TokenNotAllowlisted(token);

        bytes32 key = receiptKey(msg.sender, orderId);
        if (_receipts[key].number != 0) revert ReceiptAlreadyExists(msg.sender, orderId);

        (uint256 swarmAmount, uint256 treasuryAmount, bool discounted) = _quote(msg.sender);
        address swarm = swarmRecipient;
        address treasury = treasuryRecipient;

        // Effects before interactions.
        number = ++receiptCount;
        _receipts[key] = Receipt({
            number: number,
            payer: msg.sender,
            orderId: orderId,
            token: allowed,
            swarmAmount: swarmAmount,
            treasuryAmount: treasuryAmount,
            swarmRecipient: swarm,
            treasuryRecipient: discounted ? address(0) : treasury,
            identityDiscount: discounted,
            paidAt: uint64(block.timestamp)
        });
        receiptKeyByNumber[number] = key;
        emit PaymentReceived(number, msg.sender, orderId, allowed, swarmAmount, treasuryAmount, discounted);

        _safeTransferFrom(allowed, msg.sender, swarm, swarmAmount);
        if (treasuryAmount != 0) _safeTransferFrom(allowed, msg.sender, treasury, treasuryAmount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The receipt key for a payer and order id.
    function receiptKey(address payer, bytes32 orderId) public pure returns (bytes32) {
        return keccak256(abi.encode(payer, orderId));
    }

    /// @notice The stored receipt for (payer, orderId); `number == 0` when unpaid.
    function getReceipt(address payer, bytes32 orderId) external view returns (Receipt memory) {
        return _receipts[receiptKey(payer, orderId)];
    }

    /// @notice The stored receipt with sequential number `number`; `number == 0` in the result when none.
    function getReceiptByNumber(uint256 number) external view returns (Receipt memory) {
        return _receipts[receiptKeyByNumber[number]];
    }

    /// @notice Whether (payer, orderId) has been paid.
    function isPaid(address payer, bytes32 orderId) external view returns (bool) {
        return _receipts[receiptKey(payer, orderId)].number != 0;
    }

    /// @notice What `payer` would pay now.
    /// @return total Total token amount pulled from the payer.
    /// @return swarmAmount Amount to the swarm-funding recipient.
    /// @return treasuryAmount Amount to the treasury recipient (0 for identity NFT holders).
    /// @return identityDiscount Whether the payer holds the configured identity NFT.
    function quote(address payer)
        external
        view
        returns (uint256 total, uint256 swarmAmount, uint256 treasuryAmount, bool identityDiscount)
    {
        (swarmAmount, treasuryAmount, identityDiscount) = _quote(payer);
        total = swarmAmount + treasuryAmount;
    }

    /// @notice Whether every setting required to unpause has been configured.
    function isConfigured() public view returns (bool) {
        return paymentToken != address(0) && swarmRecipient != address(0) && treasuryRecipient != address(0)
            && identityNft != address(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner configuration
    // ---------------------------------------------------------------------------------------------

    /// @notice Allowlists `token` as the single accepted payment token. Reads and stores its decimals.
    function setPaymentToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NotAContract(token);
        uint8 decimals = _readDecimals(token);
        if (decimals < MIN_TOKEN_DECIMALS || decimals > MAX_TOKEN_DECIMALS) revert UnsupportedTokenDecimals(decimals);
        emit PaymentTokenSet(paymentToken, token, decimals);
        paymentToken = token;
        paymentTokenDecimals = decimals;
    }

    /// @notice Sets the swarm-funding recipient (receives 0.50 units per payment).
    function setSwarmRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == treasuryRecipient) revert RecipientsMustDiffer();
        emit SwarmRecipientSet(swarmRecipient, recipient);
        swarmRecipient = recipient;
    }

    /// @notice Sets the treasury recipient (receives 0.25 units per standard payment).
    function setTreasuryRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (recipient == swarmRecipient) revert RecipientsMustDiffer();
        emit TreasuryRecipientSet(treasuryRecipient, recipient);
        treasuryRecipient = recipient;
    }

    /// @notice Sets the ERC-721 identity NFT whose holders pay the discounted price.
    function setIdentityNft(address nft) external onlyOwner {
        if (nft == address(0)) revert ZeroAddress();
        if (nft.code.length == 0) revert NotAContract(nft);
        emit IdentityNftSet(identityNft, nft);
        identityNft = nft;
    }

    /// @notice Stops new payments. Existing receipts are unaffected.
    function pause() external onlyOwner {
        if (paused) revert IsPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Resumes payments. Requires every setting to be configured.
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        if (paymentToken == address(0)) revert PaymentTokenNotConfigured();
        if (swarmRecipient == address(0)) revert SwarmRecipientNotConfigured();
        if (treasuryRecipient == address(0)) revert TreasuryRecipientNotConfigured();
        if (identityNft == address(0)) revert IdentityNftNotConfigured();
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Ownership (two-step)
    // ---------------------------------------------------------------------------------------------

    /// @notice Starts a transfer of ownership to `newOwner`, who must call `acceptOwnership`.
    /// @dev Passing address(0) cancels a pending transfer.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice Completes a pending ownership transfer.
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------------------------------

    function _quote(address payer)
        internal
        view
        returns (uint256 swarmAmount, uint256 treasuryAmount, bool discounted)
    {
        if (paymentToken == address(0)) {
            revert PaymentTokenNotConfigured();
        }
        uint256 unit = 10 ** uint256(paymentTokenDecimals);
        swarmAmount = (unit * SWARM_SHARE_CENTS) / 100;
        address nft = identityNft;
        discounted = nft != address(0) && IERC721Minimal(nft).balanceOf(payer) > 0;
        treasuryAmount = discounted ? 0 : (unit * TREASURY_SHARE_CENTS) / 100;
    }

    function _readDecimals(address token) internal view returns (uint8) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length < 32) revert TokenDecimalsUnavailable(token);
        uint256 value = abi.decode(data, (uint256));
        if (value > type(uint8).max) revert TokenDecimalsUnavailable(token);
        return uint8(value);
    }

    /// @dev Accepts tokens that return true or nothing; rejects false returns and reverts.
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))) {
            revert TokenTransferFailed(token, from, to, amount);
        }
    }
}
