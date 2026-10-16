// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FolirPayments} from "../src/FolirPayments.sol";
import {
    MockERC20,
    MockERC721,
    FalseReturningERC20,
    NoReturnERC20,
    NoDecimalsToken,
    ReentrantERC20
} from "./mocks/Mocks.sol";

contract FolirPaymentsTest is Test {
    address internal constant LAUNCH_OWNER = 0xd470133A27B58a2949D2a0BE9414204dB3eb0aB4;

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

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(payments), type(uint256).max);
    }

    // ------------------------------------------------------------------ deployment

    function test_constructor_setsOwnerAndStartsPaused() public view {
        assertEq(payments.owner(), owner);
        assertTrue(payments.paused());
        assertFalse(payments.isConfigured());
        assertEq(payments.paymentToken(), address(0));
        assertEq(payments.receiptCount(), 0);
    }

    function test_constructor_ownerIsArgumentNotDeployer() public {
        FolirPayments p = new FolirPayments(LAUNCH_OWNER);
        assertEq(p.owner(), LAUNCH_OWNER);
        assertTrue(p.owner() != address(this));
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(FolirPayments.ZeroAddress.selector);
        new FolirPayments(address(0));
    }

    // ------------------------------------------------------------------ unconfigured state

    function test_pay_revertsWhilePaused() public {
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(FolirPayments.IsPaused.selector);
        payments.pay(ORDER, address(token));
    }

    function test_quote_revertsWhenTokenNotConfigured() public {
        vm.expectRevert(FolirPayments.PaymentTokenNotConfigured.selector);
        payments.quote(alice);
    }

    function test_unpause_revertsUntilEachSettingConfigured() public {
        vm.startPrank(owner);
        vm.expectRevert(FolirPayments.PaymentTokenNotConfigured.selector);
        payments.unpause();

        payments.setPaymentToken(address(token));
        vm.expectRevert(FolirPayments.SwarmRecipientNotConfigured.selector);
        payments.unpause();

        payments.setSwarmRecipient(swarm);
        vm.expectRevert(FolirPayments.TreasuryRecipientNotConfigured.selector);
        payments.unpause();

        payments.setTreasuryRecipient(treasury);
        vm.expectRevert(FolirPayments.IdentityNftNotConfigured.selector);
        payments.unpause();

        payments.setIdentityNft(address(nft));
        assertTrue(payments.isConfigured());
        payments.unpause();
        vm.stopPrank();
        assertFalse(payments.paused());
    }

    // ------------------------------------------------------------------ configuration

    function test_setters_emitEventsAndStore() public {
        vm.startPrank(owner);
        vm.expectEmit(true, true, false, true, address(payments));
        emit FolirPayments.PaymentTokenSet(address(0), address(token), 18);
        payments.setPaymentToken(address(token));

        vm.expectEmit(true, true, false, false, address(payments));
        emit FolirPayments.SwarmRecipientSet(address(0), swarm);
        payments.setSwarmRecipient(swarm);

        vm.expectEmit(true, true, false, false, address(payments));
        emit FolirPayments.TreasuryRecipientSet(address(0), treasury);
        payments.setTreasuryRecipient(treasury);

        vm.expectEmit(true, true, false, false, address(payments));
        emit FolirPayments.IdentityNftSet(address(0), address(nft));
        payments.setIdentityNft(address(nft));
        vm.stopPrank();

        assertEq(payments.paymentToken(), address(token));
        assertEq(payments.paymentTokenDecimals(), 18);
        assertEq(payments.swarmRecipient(), swarm);
        assertEq(payments.treasuryRecipient(), treasury);
        assertEq(payments.identityNft(), address(nft));
    }

    function test_setters_onlyOwner() public {
        vm.startPrank(alice);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setPaymentToken(address(token));
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setSwarmRecipient(swarm);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setTreasuryRecipient(treasury);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setIdentityNft(address(nft));
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.unpause();
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.pause();
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_setters_rejectZeroAddresses() public {
        vm.startPrank(owner);
        vm.expectRevert(FolirPayments.ZeroAddress.selector);
        payments.setPaymentToken(address(0));
        vm.expectRevert(FolirPayments.ZeroAddress.selector);
        payments.setSwarmRecipient(address(0));
        vm.expectRevert(FolirPayments.ZeroAddress.selector);
        payments.setTreasuryRecipient(address(0));
        vm.expectRevert(FolirPayments.ZeroAddress.selector);
        payments.setIdentityNft(address(0));
        vm.stopPrank();
    }

    function test_setters_rejectEoaTokenAndNft() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.NotAContract.selector, alice));
        payments.setPaymentToken(alice);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.NotAContract.selector, alice));
        payments.setIdentityNft(alice);
        vm.stopPrank();
    }

    function test_setPaymentToken_rejectsMissingOrUnsupportedDecimals() public {
        NoDecimalsToken noDecimals = new NoDecimalsToken();
        MockERC20 oneDecimal = new MockERC20(1);
        MockERC20 tooMany = new MockERC20(37);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenDecimalsUnavailable.selector, address(noDecimals)));
        payments.setPaymentToken(address(noDecimals));
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.UnsupportedTokenDecimals.selector, uint8(1)));
        payments.setPaymentToken(address(oneDecimal));
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.UnsupportedTokenDecimals.selector, uint8(37)));
        payments.setPaymentToken(address(tooMany));
        vm.stopPrank();
    }

    function test_recipients_mustDiffer() public {
        vm.startPrank(owner);
        payments.setSwarmRecipient(swarm);
        vm.expectRevert(FolirPayments.RecipientsMustDiffer.selector);
        payments.setTreasuryRecipient(swarm);
        payments.setTreasuryRecipient(treasury);
        vm.expectRevert(FolirPayments.RecipientsMustDiffer.selector);
        payments.setSwarmRecipient(treasury);
        vm.stopPrank();
    }

    function test_pause_unpause_transitions() public {
        _configure();
        vm.startPrank(owner);
        vm.expectRevert(FolirPayments.NotPaused.selector);
        payments.unpause();
        payments.pause();
        assertTrue(payments.paused());
        vm.expectRevert(FolirPayments.IsPaused.selector);
        payments.pause();
        vm.stopPrank();

        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(FolirPayments.IsPaused.selector);
        payments.pay(ORDER, address(token));
    }

    // ------------------------------------------------------------------ payments

    function test_pay_standardSplitsToSwarmAndTreasury() public {
        _configure();
        _fund(alice, 1e18);

        (uint256 total, uint256 s, uint256 t, bool discounted) = payments.quote(alice);
        assertEq(total, 0.75e18);
        assertEq(s, 0.5e18);
        assertEq(t, 0.25e18);
        assertFalse(discounted);

        vm.expectEmit(true, true, true, true, address(payments));
        emit FolirPayments.PaymentReceived(1, alice, ORDER, address(token), 0.5e18, 0.25e18, false);
        vm.prank(alice);
        uint256 number = payments.pay(ORDER, address(token));

        assertEq(number, 1);
        assertEq(token.balanceOf(swarm), 0.5e18);
        assertEq(token.balanceOf(treasury), 0.25e18);
        assertEq(token.balanceOf(alice), 0.25e18);
        assertEq(token.balanceOf(address(payments)), 0);

        FolirPayments.Receipt memory r = payments.getReceipt(alice, ORDER);
        assertEq(r.number, 1);
        assertEq(r.payer, alice);
        assertEq(r.orderId, ORDER);
        assertEq(r.token, address(token));
        assertEq(r.swarmAmount, 0.5e18);
        assertEq(r.treasuryAmount, 0.25e18);
        assertEq(r.swarmRecipient, swarm);
        assertEq(r.treasuryRecipient, treasury);
        assertFalse(r.identityDiscount);
        assertEq(r.paidAt, block.timestamp);
        assertTrue(payments.isPaid(alice, ORDER));
        assertEq(payments.getReceiptByNumber(1).payer, alice);
        assertEq(payments.receiptKeyByNumber(1), payments.receiptKey(alice, ORDER));
    }

    function test_pay_identityHolderPaysHalfWithNoTreasury() public {
        _configure();
        nft.mint(bob, 7);
        _fund(bob, 1e18);

        (uint256 total,, uint256 t, bool discounted) = payments.quote(bob);
        assertEq(total, 0.5e18);
        assertEq(t, 0);
        assertTrue(discounted);

        vm.prank(bob);
        payments.pay(ORDER, address(token));

        assertEq(token.balanceOf(swarm), 0.5e18);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(token.balanceOf(bob), 0.5e18);
        FolirPayments.Receipt memory r = payments.getReceipt(bob, ORDER);
        assertTrue(r.identityDiscount);
        assertEq(r.treasuryAmount, 0);
        assertEq(r.treasuryRecipient, address(0));
    }

    function test_pay_discountFollowsCurrentNftHolding() public {
        _configure();
        nft.mint(bob, 1);
        _fund(bob, 2e18);
        vm.prank(bob);
        payments.pay(keccak256("a"), address(token));
        nft.burn(1);
        vm.prank(bob);
        payments.pay(keccak256("b"), address(token));
        assertEq(token.balanceOf(swarm), 1e18);
        assertEq(token.balanceOf(treasury), 0.25e18);
    }

    function test_pay_usesTokenDecimals() public {
        MockERC20 usdc = new MockERC20(6);
        _configure();
        vm.prank(owner);
        payments.setPaymentToken(address(usdc));
        usdc.mint(alice, 1e6);
        vm.startPrank(alice);
        usdc.approve(address(payments), 1e6);
        payments.pay(ORDER, address(usdc));
        vm.stopPrank();
        assertEq(usdc.balanceOf(swarm), 500_000);
        assertEq(usdc.balanceOf(treasury), 250_000);
    }

    function test_pay_duplicateReceiptReverts() public {
        _configure();
        _fund(alice, 2e18);
        vm.startPrank(alice);
        payments.pay(ORDER, address(token));
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.ReceiptAlreadyExists.selector, alice, ORDER));
        payments.pay(ORDER, address(token));
        vm.stopPrank();
        assertEq(payments.receiptCount(), 1);
        assertEq(token.balanceOf(alice), 1.25e18);
    }

    function test_pay_sameOrderIdDifferentPayersAreIndependent() public {
        _configure();
        _fund(alice, 1e18);
        _fund(bob, 1e18);
        vm.prank(alice);
        assertEq(payments.pay(ORDER, address(token)), 1);
        vm.prank(bob);
        assertEq(payments.pay(ORDER, address(token)), 2);
        assertEq(payments.getReceipt(alice, ORDER).number, 1);
        assertEq(payments.getReceipt(bob, ORDER).number, 2);
    }

    function test_pay_zeroOrderIdReverts() public {
        _configure();
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(FolirPayments.ZeroOrderId.selector);
        payments.pay(bytes32(0), address(token));
    }

    function test_pay_wrongTokenReverts() public {
        _configure();
        MockERC20 other = new MockERC20(18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenNotAllowlisted.selector, address(other)));
        payments.pay(ORDER, address(other));
    }

    function test_pay_afterTokenChangeOldTokenRejected() public {
        _configure();
        MockERC20 next = new MockERC20(18);
        vm.prank(owner);
        payments.setPaymentToken(address(next));
        _fund(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.TokenNotAllowlisted.selector, address(token)));
        payments.pay(ORDER, address(token));
    }

    function test_pay_insufficientAllowanceRevertsAndLeavesNoReceipt() public {
        _configure();
        token.mint(alice, 1e18);
        vm.startPrank(alice);
        token.approve(address(payments), 0.5e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(token), alice, treasury, uint256(0.25e18)
            )
        );
        payments.pay(ORDER, address(token));
        vm.stopPrank();
        assertFalse(payments.isPaid(alice, ORDER));
        assertEq(payments.receiptCount(), 0);
        assertEq(token.balanceOf(alice), 1e18);
    }

    function test_pay_insufficientBalanceReverts() public {
        _configure();
        _fund(alice, 0.7e18);
        vm.prank(alice);
        vm.expectRevert();
        payments.pay(ORDER, address(token));
        assertFalse(payments.isPaid(alice, ORDER));
    }

    function test_pay_falseReturningTokenReverts() public {
        FalseReturningERC20 bad = new FalseReturningERC20();
        _configure();
        vm.prank(owner);
        payments.setPaymentToken(address(bad));
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                FolirPayments.TokenTransferFailed.selector, address(bad), alice, swarm, uint256(0.5e18)
            )
        );
        payments.pay(ORDER, address(bad));
        assertFalse(payments.isPaid(alice, ORDER));
    }

    function test_pay_noReturnTokenAccepted() public {
        NoReturnERC20 usdt = new NoReturnERC20();
        _configure();
        vm.prank(owner);
        payments.setPaymentToken(address(usdt));
        usdt.mint(alice, 1e6);
        vm.startPrank(alice);
        usdt.approve(address(payments), 1e6);
        payments.pay(ORDER, address(usdt));
        vm.stopPrank();
        assertEq(usdt.balanceOf(swarm), 500_000);
        assertEq(usdt.balanceOf(treasury), 250_000);
    }

    function test_pay_reentrancyBlocked() public {
        ReentrantERC20 evil = new ReentrantERC20();
        _configure();
        vm.prank(owner);
        payments.setPaymentToken(address(evil));
        evil.setTarget(address(payments));
        evil.mint(alice, 2e18);
        vm.prank(alice);
        evil.approve(address(payments), type(uint256).max);

        vm.prank(alice);
        payments.pay(ORDER, address(evil));
        assertTrue(evil.attacked());
        assertEq(evil.lastRevert(), abi.encodeWithSelector(FolirPayments.Reentrancy.selector));
        assertEq(payments.receiptCount(), 1);
        assertFalse(payments.isPaid(address(evil), keccak256("reenter")));
        assertEq(evil.balanceOf(alice), 1.25e18);
    }

    function test_pay_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(payments).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ ownership

    function test_ownership_twoStepTransfer() public {
        vm.prank(owner);
        payments.transferOwnership(alice);
        assertEq(payments.owner(), owner);
        assertEq(payments.pendingOwner(), alice);

        vm.prank(bob);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();

        vm.prank(alice);
        payments.acceptOwnership();
        assertEq(payments.owner(), alice);
        assertEq(payments.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setSwarmRecipient(swarm);
    }

    function test_ownership_cancelPendingTransfer() public {
        vm.startPrank(owner);
        payments.transferOwnership(alice);
        payments.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(FolirPayments.NotPendingOwner.selector);
        payments.acceptOwnership();
    }

    // ------------------------------------------------------------------ fuzz

    /// Conservation: payer loses exactly what the recipients gain; contract holds nothing.
    function testFuzz_pay_conservesFunds(uint8 decimals, bool holder, bytes32 orderId, uint96 extra) public {
        decimals = uint8(bound(decimals, 2, 36));
        vm.assume(orderId != bytes32(0));
        MockERC20 t = new MockERC20(decimals);
        _configure();
        vm.prank(owner);
        payments.setPaymentToken(address(t));
        if (holder) nft.mint(alice, 1);

        uint256 unit = 10 ** uint256(decimals);
        uint256 start = unit + extra;
        t.mint(alice, start);
        vm.prank(alice);
        t.approve(address(payments), type(uint256).max);

        vm.prank(alice);
        payments.pay(orderId, address(t));

        uint256 swarmGot = t.balanceOf(swarm);
        uint256 treasuryGot = t.balanceOf(treasury);
        assertEq(swarmGot, unit / 2);
        assertEq(treasuryGot, holder ? 0 : unit / 4);
        assertEq(start - t.balanceOf(alice), swarmGot + treasuryGot);
        assertEq(t.balanceOf(address(payments)), 0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FolirPayments.ReceiptAlreadyExists.selector, alice, orderId));
        payments.pay(orderId, address(t));
    }

    function testFuzz_setters_rejectNonOwner(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(FolirPayments.NotOwner.selector);
        payments.setSwarmRecipient(swarm);
    }
}
