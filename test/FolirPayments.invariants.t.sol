// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {FolirPayments} from "../src/FolirPayments.sol";
import {MockERC20, MockERC721, NoDecimalsToken} from "./mocks/Mocks.sol";

/// @dev Drives FolirPayments with random owner, payer and stranger actions. Every call predicts its
/// outcome from the observable state before the call and asserts that outcome after it, and keeps ghost
/// accounting of every token that was minted, spent and received.
contract FolirHandler is Test {
    FolirPayments public p;

    address[] public payers;
    address[] public recipients;
    address[] public ownerCandidates;
    MockERC20[] public tokens;
    MockERC721[] public nfts;
    bytes32[] public orderIds;
    NoDecimalsToken public badToken;
    address public eoa = makeAddr("eoa");

    // ghosts -------------------------------------------------------------------------------------
    uint256 public ghostReceipts;
    uint256 public ghostFailedPays;
    uint256 public ghostDiscountedReceipts;
    mapping(address token => mapping(address who => uint256)) public ghostMinted;
    mapping(address token => mapping(address who => uint256)) public ghostSpent;
    mapping(address token => mapping(address who => uint256)) public ghostReceived;
    mapping(uint256 number => bytes32) public ghostReceiptHash;
    mapping(bytes32 key => bool) public ghostPaid;

    struct Minted {
        uint256 nft;
        address holder;
        uint256 id;
    }

    Minted[] internal _minted;
    uint256 internal _nextId = 1;

    constructor(FolirPayments p_, address ownerA, address ownerB) {
        p = p_;
        ownerCandidates.push(ownerA);
        ownerCandidates.push(ownerB);
        for (uint256 i; i < 4; ++i) {
            payers.push(makeAddr(string.concat("payer", vm.toString(i))));
            recipients.push(makeAddr(string.concat("recipient", vm.toString(i))));
        }
        tokens.push(new MockERC20(2));
        tokens.push(new MockERC20(6));
        tokens.push(new MockERC20(18));
        tokens.push(new MockERC20(36));
        nfts.push(new MockERC721());
        nfts.push(new MockERC721());
        for (uint256 i; i < 6; ++i) {
            orderIds.push(keccak256(abi.encode("order", i)));
        }
        badToken = new NoDecimalsToken();
    }

    // views for the invariants -------------------------------------------------------------------

    function payerCount() external view returns (uint256) {
        return payers.length;
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    function orderIdCount() external view returns (uint256) {
        return orderIds.length;
    }

    function ownerCandidateCount() external view returns (uint256) {
        return ownerCandidates.length;
    }

    function receiptHash(FolirPayments.Receipt memory r) public pure returns (bytes32) {
        return keccak256(abi.encode(r));
    }

    // payer actions ------------------------------------------------------------------------------

    struct PayCtx {
        address payer;
        bytes32 orderId;
        address token;
        address allowed;
        uint256 total;
        uint256 swarmAmount;
        uint256 treasuryAmount;
        bool discounted;
        address swarmBefore;
        address treasuryBefore;
        uint256 countBefore;
        bytes expected;
    }

    /// @param mode 0: fully funded, 1: allowance one wei short, 2: balance one wei short,
    ///             3: wrong token, 4: zero order id, 5: fully funded with surplus balance,
    ///             6: payer is given the configured identity NFT first, then fully funded.
    function pay(uint256 payerSeed, uint256 orderSeed, uint256 mode, uint256 tokenSeed) external {
        PayCtx memory c;
        c.payer = payers[bound(payerSeed, 0, payers.length - 1)];
        c.orderId = orderIds[bound(orderSeed, 0, orderIds.length - 1)];
        mode = bound(mode, 0, 6);
        if (mode == 6) _giveConfiguredNft(c.payer);
        c.allowed = p.paymentToken();
        c.token = c.allowed;
        if (mode == 3) {
            c.token = address(tokens[bound(tokenSeed, 0, tokens.length - 1)]);
            if (c.token == c.allowed) c.token = address(badToken);
        }
        if (mode == 4) c.orderId = bytes32(0);

        if (c.allowed != address(0)) {
            (c.total, c.swarmAmount, c.treasuryAmount, c.discounted) = p.quote(c.payer);
            _fund(c, mode);
        }
        c.expected = _predict(c);
        c.countBefore = p.receiptCount();
        c.swarmBefore = p.swarmRecipient();
        c.treasuryBefore = p.treasuryRecipient();

        vm.prank(c.payer);
        try p.pay(c.orderId, c.token) returns (uint256 number) {
            _afterSuccess(c, number);
        } catch (bytes memory reason) {
            _afterFailure(c, reason);
        }
    }

    function _giveConfiguredNft(address payer) internal {
        address configured = p.identityNft();
        for (uint256 n; n < nfts.length; ++n) {
            if (address(nfts[n]) == configured) {
                uint256 id = _nextId++;
                nfts[n].mint(payer, id);
                _minted.push(Minted({nft: n, holder: payer, id: id}));
            }
        }
    }

    function _fund(PayCtx memory c, uint256 mode) internal {
        MockERC20 t = MockERC20(c.allowed);
        uint256 target = c.total;
        if (mode == 2) target = c.total - 1;
        if (mode == 5) target = c.total * 3;
        uint256 have = t.balanceOf(c.payer);
        if (have < target) {
            t.mint(c.payer, target - have);
            ghostMinted[c.allowed][c.payer] += target - have;
        }
        uint256 allowance = mode == 1 ? c.total - 1 : c.total;
        vm.prank(c.payer);
        t.approve(address(p), allowance);
    }

    function _predict(PayCtx memory c) internal view returns (bytes memory expected) {
        if (p.paused()) return abi.encodeWithSelector(FolirPayments.IsPaused.selector);
        if (c.orderId == bytes32(0)) return abi.encodeWithSelector(FolirPayments.ZeroOrderId.selector);
        if (c.token != c.allowed) return abi.encodeWithSelector(FolirPayments.TokenNotAllowlisted.selector, c.token);
        if (p.isPaid(c.payer, c.orderId)) {
            return abi.encodeWithSelector(FolirPayments.ReceiptAlreadyExists.selector, c.payer, c.orderId);
        }
        MockERC20 t = MockERC20(c.allowed);
        uint256 bal = t.balanceOf(c.payer);
        uint256 alw = t.allowance(c.payer, address(p));
        if (bal < c.swarmAmount || alw < c.swarmAmount) {
            return abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, c.allowed, c.payer, p.swarmRecipient(), c.swarmAmount
            );
        }
        if (c.treasuryAmount != 0 && (bal - c.swarmAmount < c.treasuryAmount || alw - c.swarmAmount < c.treasuryAmount))
        {
            return abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, c.allowed, c.payer, p.treasuryRecipient(), c.treasuryAmount
            );
        }
        return "";
    }

    function _afterSuccess(PayCtx memory c, uint256 number) internal {
        assertEq(c.expected.length, 0, "pay succeeded where a revert was predicted");
        assertEq(number, c.countBefore + 1, "receipt number not sequential");
        assertEq(p.receiptCount(), number, "receiptCount != returned number");
        assertTrue(p.isPaid(c.payer, c.orderId), "isPaid false after pay");

        FolirPayments.Receipt memory r = p.getReceipt(c.payer, c.orderId);
        assertEq(r.number, number);
        assertEq(r.payer, c.payer);
        assertEq(r.orderId, c.orderId);
        assertEq(r.token, c.allowed);
        assertEq(r.swarmAmount, c.swarmAmount);
        assertEq(r.treasuryAmount, c.treasuryAmount);
        assertEq(r.swarmRecipient, c.swarmBefore);
        assertEq(r.treasuryRecipient, c.discounted ? address(0) : c.treasuryBefore);
        assertEq(r.identityDiscount, c.discounted);
        assertEq(r.paidAt, uint64(block.timestamp));
        assertEq(receiptHash(p.getReceiptByNumber(number)), receiptHash(r), "lookup by number differs");

        ghostReceipts += 1;
        if (c.discounted) ghostDiscountedReceipts += 1;
        ghostReceiptHash[number] = receiptHash(r);
        ghostPaid[p.receiptKey(c.payer, c.orderId)] = true;
        ghostSpent[c.allowed][c.payer] += c.total;
        ghostReceived[c.allowed][c.swarmBefore] += c.swarmAmount;
        if (c.treasuryAmount != 0) ghostReceived[c.allowed][c.treasuryBefore] += c.treasuryAmount;
    }

    function _afterFailure(PayCtx memory c, bytes memory reason) internal {
        assertGt(c.expected.length, 0, "pay reverted where success was predicted");
        assertEq(reason, c.expected, "pay reverted with an unexpected reason");
        assertEq(p.receiptCount(), c.countBefore, "receiptCount changed by a failed pay");
        assertEq(ghostPaid[p.receiptKey(c.payer, c.orderId)], p.isPaid(c.payer, c.orderId), "failed pay changed isPaid");
        ghostFailedPays += 1;
    }

    function mintNft(uint256 payerSeed, uint256 nftSeed) external {
        address payer = payers[bound(payerSeed, 0, payers.length - 1)];
        uint256 n = bound(nftSeed, 0, nfts.length - 1);
        uint256 id = _nextId++;
        nfts[n].mint(payer, id);
        _minted.push(Minted({nft: n, holder: payer, id: id}));
    }

    function burnNft(uint256 seed) external {
        if (_minted.length == 0) return;
        uint256 i = bound(seed, 0, _minted.length - 1);
        Minted memory m = _minted[i];
        nfts[m.nft].burn(m.id);
        _minted[i] = _minted[_minted.length - 1];
        _minted.pop();
    }

    // owner actions ------------------------------------------------------------------------------

    function ownerPause() external {
        bytes memory expected = p.paused() ? abi.encodeWithSelector(FolirPayments.IsPaused.selector) : bytes("");
        vm.prank(p.owner());
        try p.pause() {
            assertEq(expected.length, 0, "pause succeeded while paused");
            assertTrue(p.paused());
        } catch (bytes memory reason) {
            assertEq(reason, expected, "pause: unexpected revert");
        }
    }

    function ownerUnpause() external {
        bytes memory expected;
        if (!p.paused()) {
            expected = abi.encodeWithSelector(FolirPayments.NotPaused.selector);
        } else if (p.paymentToken() == address(0)) {
            expected = abi.encodeWithSelector(FolirPayments.PaymentTokenNotConfigured.selector);
        } else if (p.swarmRecipient() == address(0)) {
            expected = abi.encodeWithSelector(FolirPayments.SwarmRecipientNotConfigured.selector);
        } else if (p.treasuryRecipient() == address(0)) {
            expected = abi.encodeWithSelector(FolirPayments.TreasuryRecipientNotConfigured.selector);
        } else if (p.identityNft() == address(0)) {
            expected = abi.encodeWithSelector(FolirPayments.IdentityNftNotConfigured.selector);
        }
        vm.prank(p.owner());
        try p.unpause() {
            assertEq(expected.length, 0, "unpause succeeded where a revert was predicted");
            assertFalse(p.paused());
            assertTrue(p.isConfigured(), "unpaused while not configured");
        } catch (bytes memory reason) {
            assertEq(reason, expected, "unpause: unexpected revert");
        }
    }

    /// @param seed selects one of the good tokens, the no-decimals token, an EOA or the zero address.
    function ownerSetPaymentToken(uint256 seed) external {
        uint256 choice = bound(seed, 0, tokens.length + 2);
        address token;
        bytes memory expected;
        if (choice < tokens.length) {
            token = address(tokens[choice]);
        } else if (choice == tokens.length) {
            token = address(badToken);
            expected = abi.encodeWithSelector(FolirPayments.TokenDecimalsUnavailable.selector, token);
        } else if (choice == tokens.length + 1) {
            token = eoa;
            expected = abi.encodeWithSelector(FolirPayments.NotAContract.selector, token);
        } else {
            expected = abi.encodeWithSelector(FolirPayments.ZeroAddress.selector);
        }
        address before = p.paymentToken();
        vm.prank(p.owner());
        try p.setPaymentToken(token) {
            assertEq(expected.length, 0, "setPaymentToken succeeded where a revert was predicted");
            assertEq(p.paymentToken(), token);
            assertEq(p.paymentTokenDecimals(), MockERC20(token).decimals());
        } catch (bytes memory reason) {
            assertEq(reason, expected, "setPaymentToken: unexpected revert");
            assertEq(p.paymentToken(), before);
        }
    }

    function ownerSetSwarmRecipient(uint256 seed) external {
        address r = _pickRecipient(seed);
        bytes memory expected;
        if (r == address(0)) {
            expected = abi.encodeWithSelector(FolirPayments.ZeroAddress.selector);
        } else if (r == p.treasuryRecipient()) {
            expected = abi.encodeWithSelector(FolirPayments.RecipientsMustDiffer.selector);
        }
        address before = p.swarmRecipient();
        vm.prank(p.owner());
        try p.setSwarmRecipient(r) {
            assertEq(expected.length, 0, "setSwarmRecipient succeeded where a revert was predicted");
            assertEq(p.swarmRecipient(), r);
        } catch (bytes memory reason) {
            assertEq(reason, expected, "setSwarmRecipient: unexpected revert");
            assertEq(p.swarmRecipient(), before);
        }
    }

    function ownerSetTreasuryRecipient(uint256 seed) external {
        address r = _pickRecipient(seed);
        bytes memory expected;
        if (r == address(0)) expected = abi.encodeWithSelector(FolirPayments.ZeroAddress.selector);
        else if (r == p.swarmRecipient()) expected = abi.encodeWithSelector(FolirPayments.RecipientsMustDiffer.selector);
        address before = p.treasuryRecipient();
        vm.prank(p.owner());
        try p.setTreasuryRecipient(r) {
            assertEq(expected.length, 0, "setTreasuryRecipient succeeded where a revert was predicted");
            assertEq(p.treasuryRecipient(), r);
        } catch (bytes memory reason) {
            assertEq(reason, expected, "setTreasuryRecipient: unexpected revert");
            assertEq(p.treasuryRecipient(), before);
        }
    }

    function ownerSetIdentityNft(uint256 seed) external {
        uint256 choice = bound(seed, 0, nfts.length + 1);
        address nft;
        bytes memory expected;
        if (choice < nfts.length) {
            nft = address(nfts[choice]);
        } else if (choice == nfts.length) {
            nft = eoa;
            expected = abi.encodeWithSelector(FolirPayments.NotAContract.selector, nft);
        } else {
            expected = abi.encodeWithSelector(FolirPayments.ZeroAddress.selector);
        }
        address before = p.identityNft();
        vm.prank(p.owner());
        try p.setIdentityNft(nft) {
            assertEq(expected.length, 0, "setIdentityNft succeeded where a revert was predicted");
            assertEq(p.identityNft(), nft);
        } catch (bytes memory reason) {
            assertEq(reason, expected, "setIdentityNft: unexpected revert");
            assertEq(p.identityNft(), before);
        }
    }

    /// @dev Starts a transfer to a candidate or cancels (zero address).
    function ownerTransferOwnership(uint256 seed) external {
        uint256 choice = bound(seed, 0, ownerCandidates.length);
        address to = choice < ownerCandidates.length ? ownerCandidates[choice] : address(0);
        address ownerBefore = p.owner();
        vm.prank(ownerBefore);
        p.transferOwnership(to);
        assertEq(p.owner(), ownerBefore, "transferOwnership changed owner directly");
        assertEq(p.pendingOwner(), to);
    }

    function acceptOwnership(uint256 seed) external {
        uint256 choice = bound(seed, 0, ownerCandidates.length + payers.length - 1);
        address caller =
            choice < ownerCandidates.length ? ownerCandidates[choice] : payers[choice - ownerCandidates.length];
        address pending = p.pendingOwner();
        address ownerBefore = p.owner();
        vm.prank(caller);
        try p.acceptOwnership() {
            assertEq(caller, pending, "acceptOwnership by someone other than the pending owner");
            assertEq(p.owner(), caller);
            assertEq(p.pendingOwner(), address(0));
        } catch (bytes memory reason) {
            assertTrue(caller != pending, "pending owner could not accept");
            assertEq(reason, abi.encodeWithSelector(FolirPayments.NotPendingOwner.selector));
            assertEq(p.owner(), ownerBefore);
        }
    }

    // stranger actions ---------------------------------------------------------------------------

    /// @dev A payer (never the owner) tries every owner-only function; all must revert with NotOwner.
    function strangerTriesOwnerFunctions(uint256 seed, uint256 which) external {
        address stranger = payers[bound(seed, 0, payers.length - 1)];
        which = bound(which, 0, 6);
        bytes memory data;
        if (which == 0) data = abi.encodeCall(p.setPaymentToken, (address(tokens[0])));
        else if (which == 1) data = abi.encodeCall(p.setSwarmRecipient, (recipients[0]));
        else if (which == 2) data = abi.encodeCall(p.setTreasuryRecipient, (recipients[1]));
        else if (which == 3) data = abi.encodeCall(p.setIdentityNft, (address(nfts[0])));
        else if (which == 4) data = abi.encodeCall(p.pause, ());
        else if (which == 5) data = abi.encodeCall(p.unpause, ());
        else data = abi.encodeCall(p.transferOwnership, (stranger));
        vm.prank(stranger);
        (bool ok, bytes memory reason) = address(p).call(data);
        assertFalse(ok, "stranger executed an owner function");
        assertEq(reason, abi.encodeWithSelector(FolirPayments.NotOwner.selector));
    }

    function warp(uint256 seed) external {
        vm.warp(block.timestamp + bound(seed, 0, 7 days));
    }

    // internal -----------------------------------------------------------------------------------

    function _pickRecipient(uint256 seed) internal view returns (address) {
        uint256 choice = bound(seed, 0, recipients.length);
        return choice < recipients.length ? recipients[choice] : address(0);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract FolirPaymentsInvariantTest is StdInvariant, Test {
    FolirPayments internal p;
    FolirHandler internal h;
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");

    function setUp() public {
        p = new FolirPayments(ownerA);
        h = new FolirHandler(p, ownerA, ownerB);

        // Start from the post-launch state: the owner has configured everything and opened payments.
        // The handler can still pause, swap every setting and move ownership from here. The road from
        // the unconfigured start is covered by the unit tests in FolirPayments.t.sol.
        vm.startPrank(ownerA);
        p.setPaymentToken(address(h.tokens(2)));
        p.setSwarmRecipient(h.recipients(0));
        p.setTreasuryRecipient(h.recipients(1));
        p.setIdentityNft(address(h.nfts(0)));
        p.unpause();
        vm.stopPrank();

        bytes4[] memory selectors = new bytes4[](16);
        selectors[0] = FolirHandler.pay.selector;
        selectors[1] = FolirHandler.pay.selector; // weight payments higher
        selectors[2] = FolirHandler.pay.selector;
        selectors[3] = FolirHandler.pay.selector;
        selectors[4] = FolirHandler.pay.selector;
        selectors[5] = FolirHandler.mintNft.selector;
        selectors[6] = FolirHandler.burnNft.selector;
        selectors[7] = FolirHandler.ownerPause.selector;
        selectors[8] = FolirHandler.ownerUnpause.selector;
        selectors[9] = FolirHandler.ownerSetPaymentToken.selector;
        selectors[10] = FolirHandler.ownerSetSwarmRecipient.selector;
        selectors[11] = FolirHandler.ownerSetTreasuryRecipient.selector;
        selectors[12] = FolirHandler.ownerSetIdentityNft.selector;
        selectors[13] = FolirHandler.ownerTransferOwnership.selector;
        selectors[14] = FolirHandler.acceptOwnership.selector;
        selectors[15] = FolirHandler.strangerTriesOwnerFunctions.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
        targetContract(address(h));
    }

    /// The contract is a pass-through: it never holds any payment token or ETH.
    function invariant_contractHoldsNothing() public view {
        for (uint256 i; i < h.tokenCount(); ++i) {
            assertEq(h.tokens(i).balanceOf(address(p)), 0, "contract holds payment tokens");
        }
        assertEq(address(p).balance, 0, "contract holds ETH");
    }

    /// Everything a payer lost went to a recipient; recipients got exactly the recorded amounts.
    function invariant_conservation() public view {
        for (uint256 i; i < h.tokenCount(); ++i) {
            MockERC20 t = h.tokens(i);
            uint256 spentSum;
            uint256 receivedSum;
            for (uint256 j; j < h.payerCount(); ++j) {
                address payer = h.payers(j);
                uint256 spent = h.ghostMinted(address(t), payer) - t.balanceOf(payer);
                assertEq(spent, h.ghostSpent(address(t), payer), "payer lost a different amount than its receipts");
                spentSum += spent;
            }
            for (uint256 j; j < h.recipientCount(); ++j) {
                address r = h.recipients(j);
                assertEq(t.balanceOf(r), h.ghostReceived(address(t), r), "recipient balance != ghost received");
                receivedSum += t.balanceOf(r);
            }
            assertEq(spentSum, receivedSum, "tokens leaked or appeared");
        }
    }

    /// receiptCount counts exactly the successful payments; numbers are dense from 1.
    function invariant_receiptCountMatchesSuccessfulPays() public view {
        assertEq(p.receiptCount(), h.ghostReceipts());
        assertEq(p.getReceiptByNumber(0).number, 0);
        assertEq(p.getReceiptByNumber(p.receiptCount() + 1).number, 0);
        assertEq(p.receiptKeyByNumber(p.receiptCount() + 1), bytes32(0));
    }

    /// A written receipt never changes, is reachable by number and by (payer, orderId), and its amounts
    /// are exactly the published prices for its token's decimals.
    function invariant_receiptsImmutableAndConsistent() public view {
        uint256 n = p.receiptCount();
        uint256 discounted;
        for (uint256 i = 1; i <= n; ++i) {
            FolirPayments.Receipt memory r = p.getReceiptByNumber(i);
            assertEq(r.number, i, "receipt number mismatch");
            assertEq(h.receiptHash(r), h.ghostReceiptHash(i), "receipt changed after it was written");
            assertEq(h.receiptHash(p.getReceipt(r.payer, r.orderId)), h.ghostReceiptHash(i), "lookup by key differs");
            assertEq(p.receiptKeyByNumber(i), p.receiptKey(r.payer, r.orderId));
            assertTrue(p.isPaid(r.payer, r.orderId));
            assertTrue(r.orderId != bytes32(0));
            assertTrue(r.payer != address(0));
            assertTrue(r.token != address(0));
            assertTrue(r.swarmRecipient != address(0));
            uint256 unit = 10 ** uint256(MockERC20(r.token).decimals());
            assertEq(r.swarmAmount * 2, unit, "swarm amount is not half a unit");
            if (r.identityDiscount) {
                assertEq(r.treasuryAmount, 0);
                assertEq(r.treasuryRecipient, address(0));
                discounted += 1;
            } else {
                assertEq(r.treasuryAmount * 4, unit, "treasury amount is not a quarter unit");
                assertTrue(r.treasuryRecipient != address(0));
                assertTrue(r.treasuryRecipient != r.swarmRecipient);
            }
        }
        assertEq(discounted, h.ghostDiscountedReceipts());
    }

    /// Nothing is marked paid that was not paid.
    function invariant_isPaidMatchesGhost() public view {
        for (uint256 i; i < h.payerCount(); ++i) {
            for (uint256 j; j < h.orderIdCount(); ++j) {
                address payer = h.payers(i);
                bytes32 orderId = h.orderIds(j);
                assertEq(p.isPaid(payer, orderId), h.ghostPaid(p.receiptKey(payer, orderId)));
            }
        }
    }

    /// Payments are only open when every setting is configured, and configuration never goes away.
    function invariant_unpausedImpliesConfigured() public view {
        if (!p.paused()) assertTrue(p.isConfigured(), "unpaused but not configured");
        assertTrue(p.isConfigured(), "a configured setting was unset");
    }

    /// Recipients never collide, and configured addresses only ever move to configured values.
    function invariant_recipientsDiffer() public view {
        address s = p.swarmRecipient();
        address t = p.treasuryRecipient();
        if (s != address(0) || t != address(0)) assertTrue(s != t, "recipients collide");
        if (p.paymentToken() != address(0)) {
            uint8 d = p.paymentTokenDecimals();
            assertTrue(d >= p.MIN_TOKEN_DECIMALS() && d <= p.MAX_TOKEN_DECIMALS());
            assertEq(d, MockERC20(p.paymentToken()).decimals());
        }
    }

    /// Ownership only ever rests with a candidate who accepted, never with the deployer, the handler,
    /// a payer, or the zero address.
    function invariant_ownerIsAlwaysACandidate() public view {
        address o = p.owner();
        assertTrue(o != address(0));
        assertTrue(o != address(this) && o != address(h));
        bool candidate;
        for (uint256 i; i < h.ownerCandidateCount(); ++i) {
            if (h.ownerCandidates(i) == o) candidate = true;
        }
        assertTrue(candidate, "owner is not a candidate");
    }

    /// Quote is internally consistent whenever it is available.
    function invariant_quoteConsistent() public view {
        if (p.paymentToken() == address(0)) return;
        uint256 unit = 10 ** uint256(p.paymentTokenDecimals());
        for (uint256 i; i < h.payerCount(); ++i) {
            (uint256 total, uint256 s, uint256 t, bool d) = p.quote(h.payers(i));
            assertEq(total, s + t);
            assertEq(s * 2, unit);
            assertEq(t, d ? 0 : unit / 4);
            assertTrue(total == unit / 2 || total == (unit * 3) / 4);
        }
    }
}
