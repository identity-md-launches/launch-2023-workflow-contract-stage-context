// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FolirPayments} from "../src/FolirPayments.sol";
import {MockERC20, MockERC721} from "./mocks/Mocks.sol";
import {
    RawDecimalsToken,
    RawReturnERC20,
    RevertingERC20,
    FeeOnTransferERC20,
    CountingReentrantERC20,
    RevertingERC721,
    ReentrantERC721,
    NotAnNft,
    ContractPayer
} from "./mocks/EdgeMocks.sol";

/// @dev Deploys and fully configures FolirPayments in a single transaction, the way a launch plus the
/// owner's follow-up would be rehearsed as one call.
contract OneShotDeployer {
    function run(address owner_, address token, address swarm, address treasury, address nft)
        external
        returns (FolirPayments p)
    {
        p = new FolirPayments(owner_);
        // The deployer is not the owner: every configuration call must fail from here.
        (bool ok,) = address(p).call(abi.encodeCall(p.setPaymentToken, (token)));
        require(!ok, "deployer could configure");
        (ok,) = address(p).call(abi.encodeCall(p.setSwarmRecipient, (swarm)));
        require(!ok, "deployer could configure");
        (ok,) = address(p).call(abi.encodeCall(p.setTreasuryRecipient, (treasury)));
        require(!ok, "deployer could configure");
        (ok,) = address(p).call(abi.encodeCall(p.setIdentityNft, (nft)));
        require(!ok, "deployer could configure");
        (ok,) = address(p).call(abi.encodeCall(p.unpause, ()));
        require(!ok, "deployer could unpause");
    }
}

/// forge-config: default.fuzz.runs = 1000
contract FolirPaymentsEdgeTest is Test {
    FolirPayments internal payments;
    MockERC20 internal token;
    MockERC721 internal nft;

    address internal owner = makeAddr("owner");
    address internal swarm = makeAddr("swarm");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    bytes32 internal constant ORDER = keccak256("order-1");

    function setUp() public {
        payments = new FolirPayments(owner);
        token = new MockERC20(18);
        nft = new MockERC721();
    }

    function _configure() internal {
        vm.startPrank(owner);
        payments.setPaymentToken(address(token));
        payments.setSwarmRecipient(swarm);
        payments.setTreasuryRecipient(treasury);
        payments.setIdentityNft(address(nft));
        payments.unpause();
        vm.stopPrank();
    }

    function _switchToken(address t) internal {
        vm.prank(owner);
        payments.setPaymentToken(t);
    }

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(payments), type(uint256).max);
    }

    // ------------------------------------------------------------------ decimals boundaries

    function test_decimals_minimumTwo_exactCents() public {
        MockERC20 cents = new MockERC20(2);
        _configure();
        _switchToken(address(cents));
        cents.mint(alice, 100);
        vm.startPrank(alice);
        cents.approve(address(payments), 75);
        (uint256 total, uint256 s, uint256 t,) = payments.quote(alice);
        assertEq(total, 75);
        assertEq(s, 50);
        assertEq(t, 25);
        payments.pay(ORDER, address(cents));
        vm.stopPrank();
        assertEq(cents.balanceOf(swarm), 50);
        assertEq(cents.balanceOf(treasury), 25);
        assertEq(cents.balanceOf(alice), 25);
    }

    function test_decimals_maximumThirtySix_noOverflow() public {
        MockERC20 big = new MockERC20(36);
        _configure();
        _switchToken(address(big));
        uint256 unit = 1e36;
        big.mint(alice, unit);
        vm.startPrank(alice);
        big.approve(address(payments), unit);
        payments.pay(ORDER, address(big));
        vm.stopPrank();
        assertEq(big.balanceOf(swarm), unit / 2);
        assertEq(big.balanceOf(treasury), unit / 4);
        assertEq(big.balanceOf(alice), unit / 4);
    }

    function test_decimals_zeroRejected() public {
        MockERC20 zero = new MockERC20(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.UnsupportedTokenDecimals.selector, uint8(0)));
        payments.setPaymentToken(address(zero));
    }

    function test_decimals_returnValueAboveUint8Rejected() public {
        RawDecimalsToken raw = new RawDecimalsToken();
        raw.setDecimalsPayload(abi.encode(uint256(256)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenDecimalsUnavailable.selector, address(raw)));
        payments.setPaymentToken(address(raw));
    }

    function test_decimals_shortReturnDataRejected() public {
        RawDecimalsToken raw = new RawDecimalsToken();
        raw.setDecimalsPayload(hex"12");
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenDecimalsUnavailable.selector, address(raw)));
        payments.setPaymentToken(address(raw));
    }

    function test_decimals_revertingRejected() public {
        RawDecimalsToken raw = new RawDecimalsToken();
        raw.setRevertOnDecimals(true);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenDecimalsUnavailable.selector, address(raw)));
        payments.setPaymentToken(address(raw));
    }

    function test_decimals_longReturnDataAccepted() public {
        RawDecimalsToken raw = new RawDecimalsToken();
        raw.setDecimalsPayload(abi.encode(uint256(8), uint256(999)));
        vm.prank(owner);
        payments.setPaymentToken(address(raw));
        assertEq(payments.paymentTokenDecimals(), 8);
    }

    // ------------------------------------------------------------------ transferFrom return shapes

    function test_transfer_shortReturnDataRejected() public {
        RawReturnERC20 raw = new RawReturnERC20();
        raw.setTransferPayload(hex"01");
        _configure();
        _switchToken(address(raw));
        raw.mint(alice, 1e6);
        vm.startPrank(alice);
        raw.approve(address(payments), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(FolirPayments.TokenTransferFailed.selector, address(raw), alice, swarm, uint256(5e5))
        );
        payments.pay(ORDER, address(raw));
        vm.stopPrank();
        assertEq(raw.balanceOf(alice), 1e6, "a rejected transfer must not move tokens");
        assertFalse(payments.isPaid(alice, ORDER));
    }

    function test_transfer_longTrueReturnDataAccepted() public {
        RawReturnERC20 raw = new RawReturnERC20();
        raw.setTransferPayload(abi.encode(true, uint256(42)));
        _configure();
        _switchToken(address(raw));
        raw.mint(alice, 1e6);
        vm.startPrank(alice);
        raw.approve(address(payments), 1e6);
        payments.pay(ORDER, address(raw));
        vm.stopPrank();
        assertEq(raw.balanceOf(swarm), 5e5);
        assertEq(raw.balanceOf(treasury), 25e4);
    }

    function test_transfer_revertWithReasonWrappedAndNoReceipt() public {
        RevertingERC20 bad = new RevertingERC20();
        _configure();
        _switchToken(address(bad));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(bad), alice, swarm, uint256(0.5e18)
            )
        );
        payments.pay(ORDER, address(bad));
        assertEq(payments.receiptCount(), 0);
    }

    /// Documented assumption: a fee-on-transfer token delivers less than the recorded amounts. The receipt
    /// records the nominal amounts, so operators must not allowlist such a token.
    function test_transfer_feeOnTransferDeliversLessThanRecorded() public {
        FeeOnTransferERC20 fee = new FeeOnTransferERC20();
        _configure();
        _switchToken(address(fee));
        fee.mint(alice, 1e18);
        vm.startPrank(alice);
        fee.approve(address(payments), 0.75e18);
        payments.pay(ORDER, address(fee));
        vm.stopPrank();
        FolirPayments.Receipt memory r = payments.getReceipt(alice, ORDER);
        assertEq(r.swarmAmount, 0.5e18);
        assertLt(fee.balanceOf(swarm), r.swarmAmount);
        assertLt(fee.balanceOf(treasury), r.treasuryAmount);
        assertEq(fee.balanceOf(address(payments)), 0);
    }

    // ------------------------------------------------------------------ allowance / balance boundaries

    function test_allowance_exactTotalSucceeds_oneWeiLessFails() public {
        _configure();
        token.mint(alice, 10e18);
        vm.startPrank(alice);
        token.approve(address(payments), 0.75e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(token), alice, treasury, uint256(0.25e18)
            )
        );
        payments.pay(ORDER, address(token));
        token.approve(address(payments), 0.75e18);
        payments.pay(ORDER, address(token));
        vm.stopPrank();
        assertEq(token.allowance(alice, address(payments)), 0);
        assertEq(token.balanceOf(alice), 10e18 - 0.75e18);
    }

    function test_allowance_discountedExactHalfSucceeds() public {
        _configure();
        nft.mint(alice, 1);
        token.mint(alice, 1e18);
        vm.startPrank(alice);
        token.approve(address(payments), 0.5e18 - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(token), alice, swarm, uint256(0.5e18)
            )
        );
        payments.pay(ORDER, address(token));
        token.approve(address(payments), 0.5e18);
        payments.pay(ORDER, address(token));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 0.5e18);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_balance_exactTotalSucceeds_oneWeiLessFails() public {
        _configure();
        _fund(alice, 0.75e18 - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(token), alice, treasury, uint256(0.25e18)
            )
        );
        payments.pay(ORDER, address(token));
        assertEq(token.balanceOf(swarm), 0, "partial transfer leaked to swarm");
        token.mint(alice, 1);
        vm.prank(alice);
        payments.pay(ORDER, address(token));
        assertEq(token.balanceOf(alice), 0);
    }

    /// A payer who approved only the discounted amount is never charged the standard price, even if the
    /// discount disappears (NFT burned) before the transaction lands.
    function test_payer_neverChargedMoreThanApproved() public {
        _configure();
        nft.mint(alice, 1);
        token.mint(alice, 1e18);
        vm.prank(alice);
        token.approve(address(payments), 0.5e18);
        nft.burn(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(token), alice, treasury, uint256(0.25e18)
            )
        );
        payments.pay(ORDER, address(token));
        assertEq(token.balanceOf(alice), 1e18);
        assertFalse(payments.isPaid(alice, ORDER));
    }

    // ------------------------------------------------------------------ identity NFT behaviour

    function test_nft_multipleHoldingsStillOneDiscount() public {
        _configure();
        nft.mint(alice, 1);
        nft.mint(alice, 2);
        nft.mint(alice, 3);
        (uint256 total,,, bool d) = payments.quote(alice);
        assertTrue(d);
        assertEq(total, 0.5e18);
    }

    function test_nft_revertingBalanceOfBlocksPaymentsUntilReplaced() public {
        RevertingERC721 down = new RevertingERC721();
        _configure();
        vm.prank(owner);
        payments.setIdentityNft(address(down));
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert("nft down");
        payments.pay(ORDER, address(token));
        vm.expectRevert("nft down");
        payments.quote(alice);
        assertFalse(payments.isPaid(alice, ORDER));
        // The owner can recover by pointing at a working NFT.
        vm.prank(owner);
        payments.setIdentityNft(address(nft));
        vm.prank(alice);
        payments.pay(ORDER, address(token));
        assertTrue(payments.isPaid(alice, ORDER));
    }

    function test_nft_withoutBalanceOfBlocksPayments() public {
        NotAnNft notNft = new NotAnNft();
        _configure();
        vm.prank(owner);
        payments.setIdentityNft(address(notNft));
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        payments.pay(ORDER, address(token));
        assertEq(payments.receiptCount(), 0);
    }

    function test_nft_cannotReenterPayFromBalanceOf() public {
        ReentrantERC721 evil = new ReentrantERC721();
        evil.setTarget(address(payments));
        _configure();
        vm.prank(owner);
        payments.setIdentityNft(address(evil));
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        payments.pay(ORDER, address(token));
        assertEq(payments.receiptCount(), 0);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_nft_switchingCollectionChangesDiscount() public {
        MockERC721 other = new MockERC721();
        _configure();
        other.mint(alice, 1);
        (,,, bool d) = payments.quote(alice);
        assertFalse(d, "holding a non-configured NFT must not discount");
        vm.prank(owner);
        payments.setIdentityNft(address(other));
        (,,, d) = payments.quote(alice);
        assertTrue(d);
    }

    // ------------------------------------------------------------------ reentrancy on the second transfer

    function test_reentrancy_blockedOnTreasuryTransfer() public {
        CountingReentrantERC20 evil = new CountingReentrantERC20();
        _configure();
        _switchToken(address(evil));
        evil.configure(address(payments), 2);
        evil.mint(alice, 2e18);
        vm.startPrank(alice);
        evil.approve(address(payments), type(uint256).max);
        payments.pay(ORDER, address(evil));
        vm.stopPrank();
        assertTrue(evil.attacked());
        assertEq(evil.calls(), 2);
        assertEq(evil.lastRevert(), abi.encodeWithSelector(FolirPayments.Reentrancy.selector));
        assertEq(payments.receiptCount(), 1);
        assertEq(evil.balanceOf(alice), 1.25e18);
        assertEq(evil.balanceOf(swarm), 0.5e18);
        assertEq(evil.balanceOf(treasury), 0.25e18);
    }

    function test_reentrancy_lockReleasedAfterPayment() public {
        CountingReentrantERC20 evil = new CountingReentrantERC20();
        _configure();
        _switchToken(address(evil));
        evil.configure(address(payments), 1);
        evil.mint(alice, 2e18);
        vm.startPrank(alice);
        evil.approve(address(payments), type(uint256).max);
        payments.pay(ORDER, address(evil));
        // A fresh, honest payment after the attack must still go through.
        payments.pay(keccak256("order-2"), address(evil));
        vm.stopPrank();
        assertEq(payments.receiptCount(), 2);
    }

    // ------------------------------------------------------------------ callers and ETH

    function test_contractPayerCanPay() public {
        ContractPayer payer = new ContractPayer();
        _configure();
        token.mint(address(payer), 1e18);
        uint256 number = payer.approveAndPay(address(token), address(payments), 0.75e18, ORDER);
        assertEq(number, 1);
        assertEq(payments.getReceipt(address(payer), ORDER).payer, address(payer));
    }

    function test_rejectsEtherWithCalldata() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(payments).call{value: 1 ether}(abi.encodeCall(payments.pay, (ORDER, address(token))));
        assertFalse(ok);
        (ok,) = address(payments).call{value: 1 ether}(hex"deadbeef");
        assertFalse(ok);
        assertEq(address(payments).balance, 0);
    }

    // ------------------------------------------------------------------ configuration changes mid-flight

    function test_recipientChange_receiptKeepsOldRecipientsAndNewPaymentUsesNew() public {
        _configure();
        _fund(alice, 2e18);
        vm.prank(alice);
        payments.pay(keccak256("a"), address(token));

        address swarm2 = makeAddr("swarm2");
        address treasury2 = makeAddr("treasury2");
        vm.startPrank(owner);
        payments.setSwarmRecipient(swarm2);
        payments.setTreasuryRecipient(treasury2);
        vm.stopPrank();

        vm.prank(alice);
        payments.pay(keccak256("b"), address(token));

        FolirPayments.Receipt memory first = payments.getReceipt(alice, keccak256("a"));
        FolirPayments.Receipt memory second = payments.getReceipt(alice, keccak256("b"));
        assertEq(first.swarmRecipient, swarm);
        assertEq(first.treasuryRecipient, treasury);
        assertEq(second.swarmRecipient, swarm2);
        assertEq(second.treasuryRecipient, treasury2);
        assertEq(token.balanceOf(swarm), 0.5e18);
        assertEq(token.balanceOf(swarm2), 0.5e18);
        assertEq(token.balanceOf(treasury), 0.25e18);
        assertEq(token.balanceOf(treasury2), 0.25e18);
    }

    function test_recipientChange_swapRequiresIntermediate() public {
        _configure();
        vm.startPrank(owner);
        vm.expectRevert(FolirPayments.RecipientsMustDiffer.selector);
        payments.setSwarmRecipient(treasury);
        // Setting a recipient to its current value is a harmless no-op.
        payments.setSwarmRecipient(swarm);
        payments.setTreasuryRecipient(treasury);
        // A swap works through an intermediate address.
        address tmp = makeAddr("tmp");
        payments.setSwarmRecipient(tmp);
        payments.setTreasuryRecipient(swarm);
        payments.setSwarmRecipient(treasury);
        vm.stopPrank();
        assertEq(payments.swarmRecipient(), treasury);
        assertEq(payments.treasuryRecipient(), swarm);
    }

    function test_tokenChange_whileUnpausedChangesDecimalsAndRejectsOld() public {
        MockERC20 six = new MockERC20(6);
        _configure();
        _fund(alice, 1e18);
        _switchToken(address(six));
        assertFalse(payments.paused(), "changing the token must not pause");
        assertEq(payments.paymentTokenDecimals(), 6);
        (uint256 total,,,) = payments.quote(alice);
        assertEq(total, 750_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenNotAllowlisted.selector, address(token)));
        payments.pay(ORDER, address(token));
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_tokenChange_receiptRecordsTokenPaidWith() public {
        MockERC20 six = new MockERC20(6);
        _configure();
        _fund(alice, 1e18);
        vm.prank(alice);
        payments.pay(keccak256("a"), address(token));
        _switchToken(address(six));
        six.mint(alice, 1e6);
        vm.startPrank(alice);
        six.approve(address(payments), 1e6);
        payments.pay(keccak256("b"), address(six));
        vm.stopPrank();
        assertEq(payments.getReceipt(alice, keccak256("a")).token, address(token));
        assertEq(payments.getReceipt(alice, keccak256("b")).token, address(six));
        assertEq(payments.getReceipt(alice, keccak256("b")).swarmAmount, 500_000);
    }

    function test_pauseDoesNotAffectExistingReceiptsAndUnpauseResumes() public {
        _configure();
        _fund(alice, 2e18);
        vm.prank(alice);
        payments.pay(keccak256("a"), address(token));
        vm.prank(owner);
        payments.pause();
        assertTrue(payments.isPaid(alice, keccak256("a")));
        assertEq(payments.getReceiptByNumber(1).number, 1);
        vm.prank(alice);
        vm.expectRevert(FolirPayments.IsPaused.selector);
        payments.pay(keccak256("b"), address(token));
        vm.prank(owner);
        payments.unpause();
        vm.prank(alice);
        assertEq(payments.pay(keccak256("b"), address(token)), 2);
    }

    function test_quote_availableWhilePaused() public {
        vm.startPrank(owner);
        payments.setPaymentToken(address(token));
        vm.stopPrank();
        (uint256 total,,, bool d) = payments.quote(alice);
        assertEq(total, 0.75e18);
        assertFalse(d, "no NFT configured means no discount");
    }

    // ------------------------------------------------------------------ ownership edge cases

    function test_ownership_secondTransferReplacesPending() public {
        vm.startPrank(owner);
        payments.transferOwnership(alice);
        payments.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
        vm.prank(bob);
        payments.acceptOwnership();
        assertEq(payments.owner(), bob);
    }

    function test_ownership_acceptWithNothingPendingReverts() public {
        vm.prank(alice);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
        assertEq(payments.owner(), owner);
    }

    function test_ownership_pendingCannotActBeforeAccepting() public {
        vm.prank(owner);
        payments.transferOwnership(alice);
        vm.prank(alice);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setSwarmRecipient(swarm);
        // The current owner keeps full control until acceptance.
        vm.prank(owner);
        payments.setSwarmRecipient(swarm);
    }

    function test_ownership_acceptCannotBeReplayed() public {
        vm.prank(owner);
        payments.transferOwnership(alice);
        vm.startPrank(alice);
        payments.acceptOwnership();
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
    }

    function test_ownership_transferToSelfIsHarmless() public {
        vm.startPrank(owner);
        payments.transferOwnership(owner);
        payments.acceptOwnership();
        vm.stopPrank();
        assertEq(payments.owner(), owner);
        assertEq(payments.pendingOwner(), address(0));
    }

    // ------------------------------------------------------------------ lookups

    function test_lookup_unknownReceiptsAreEmpty() public {
        _configure();
        FolirPayments.Receipt memory r = payments.getReceipt(alice, ORDER);
        assertEq(r.number, 0);
        assertEq(r.payer, address(0));
        assertEq(payments.getReceiptByNumber(0).number, 0);
        assertEq(payments.getReceiptByNumber(1).number, 0);
        assertEq(payments.getReceiptByNumber(type(uint256).max).number, 0);
        assertFalse(payments.isPaid(alice, ORDER));
        assertFalse(payments.isPaid(address(0), bytes32(0)));
    }

    // ------------------------------------------------------------------ one-call deployment rehearsal

    function test_oneShotDeployer_cannotConfigureAndOwnerCan() public {
        OneShotDeployer d = new OneShotDeployer();
        FolirPayments p = d.run(owner, address(token), swarm, treasury, address(nft));
        assertEq(p.owner(), owner);
        assertTrue(p.paused());
        assertFalse(p.isConfigured());
        vm.startPrank(owner);
        p.setPaymentToken(address(token));
        p.setSwarmRecipient(swarm);
        p.setTreasuryRecipient(treasury);
        p.setIdentityNft(address(nft));
        p.unpause();
        vm.stopPrank();
        assertFalse(p.paused());
    }

    // ------------------------------------------------------------------ fuzz / property tests

    /// Prices are exact for every supported decimals value: no rounding ever happens.
    function testFuzz_quote_exactForAllSupportedDecimals(uint8 decimals, bool holder) public {
        decimals = uint8(bound(decimals, 2, 36));
        MockERC20 t = new MockERC20(decimals);
        _configure();
        _switchToken(address(t));
        if (holder) nft.mint(alice, 1);
        (uint256 total, uint256 s, uint256 tr, bool d) = payments.quote(alice);
        uint256 unit = 10 ** uint256(decimals);
        assertEq(d, holder);
        assertEq(s * 2, unit);
        assertEq(tr * 4, holder ? 0 : unit);
        assertEq(total, s + tr);
        assertEq(total * 4, holder ? unit * 2 : unit * 3);
    }

    /// Unsupported decimals are rejected on both sides of the range.
    function testFuzz_decimals_outsideRangeRejected(uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 255));
        if (decimals >= 2 && decimals <= 36) decimals = decimals < 20 ? 1 : 37;
        MockERC20 t = new MockERC20(decimals);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.UnsupportedTokenDecimals.selector, decimals));
        payments.setPaymentToken(address(t));
    }

    /// Any non-zero order id from any payer gets a receipt; the same pair never gets two.
    function testFuzz_pay_anyPayerAnyOrderOnce(address payer, bytes32 orderId) public {
        vm.assume(orderId != bytes32(0));
        vm.assume(payer != address(0) && payer != swarm && payer != treasury && payer != address(payments));
        vm.assume(payer.code.length == 0);
        _configure();
        token.mint(payer, 1.5e18);
        vm.startPrank(payer);
        token.approve(address(payments), 1.5e18);
        assertEq(payments.pay(orderId, address(token)), 1);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.ReceiptAlreadyExists.selector, payer, orderId));
        payments.pay(orderId, address(token));
        vm.stopPrank();
        assertEq(token.balanceOf(payer), 0.75e18);
        assertEq(payments.receiptCount(), 1);
        assertEq(payments.getReceipt(payer, orderId).number, 1);
    }

    /// Receipt keys never collide for distinct (payer, orderId) pairs.
    function testFuzz_receiptKey_injective(address a, bytes32 x, address b, bytes32 y) public view {
        vm.assume(a != b || x != y);
        assertTrue(payments.receiptKey(a, x) != payments.receiptKey(b, y));
    }

    /// Receipt numbers are dense and ordered across many payments by many payers.
    function testFuzz_pay_numbersAreSequential(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 24));
        _configure();
        for (uint256 i = 1; i <= n; ++i) {
            address payer = address(uint160(uint256(keccak256(abi.encode(seed, i % 3)))));
            bytes32 orderId = keccak256(abi.encode(seed, i));
            token.mint(payer, 1e18);
            vm.startPrank(payer);
            token.approve(address(payments), 1e18);
            assertEq(payments.pay(orderId, address(token)), i);
            vm.stopPrank();
            assertEq(payments.getReceiptByNumber(i).orderId, orderId);
            assertEq(payments.getReceiptByNumber(i).payer, payer);
        }
        assertEq(payments.receiptCount(), n);
        assertEq(token.balanceOf(swarm), uint256(n) * 0.5e18);
        assertEq(token.balanceOf(treasury), uint256(n) * 0.25e18);
    }

    /// A payer with less than the quoted amount, in balance or allowance, is never charged anything.
    function testFuzz_pay_underfundedIsAtomic(uint256 balance, uint256 allowance, bool holder) public {
        _configure();
        if (holder) nft.mint(alice, 1);
        (uint256 total,,,) = payments.quote(alice);
        balance = bound(balance, 0, total - 1);
        allowance = bound(allowance, 0, type(uint256).max);
        token.mint(alice, balance);
        vm.startPrank(alice);
        token.approve(address(payments), allowance);
        vm.expectRevert();
        payments.pay(ORDER, address(token));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), balance);
        assertEq(token.balanceOf(swarm), 0);
        assertEq(token.balanceOf(treasury), 0);
        assertFalse(payments.isPaid(alice, ORDER));
        assertEq(payments.receiptCount(), 0);
    }

    /// Only the pending owner can accept, whoever else tries.
    function testFuzz_ownership_onlyPendingAccepts(address pending, address caller) public {
        vm.assume(pending != address(0) && caller != pending);
        vm.prank(owner);
        payments.transferOwnership(pending);
        vm.prank(caller);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
        assertEq(payments.owner(), owner);
        assertEq(payments.pendingOwner(), pending);
    }

    /// The stored timestamp is the block timestamp of the payment.
    function testFuzz_pay_recordsTimestamp(uint64 ts) public {
        ts = uint64(bound(ts, 1, type(uint64).max));
        _configure();
        _fund(alice, 1e18);
        vm.warp(ts);
        vm.prank(alice);
        payments.pay(ORDER, address(token));
        assertEq(payments.getReceipt(alice, ORDER).paidAt, ts);
    }
}
