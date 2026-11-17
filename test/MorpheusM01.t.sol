// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

struct Session {
    address user;
    bytes32 bidId;
    uint256 stake;
    bytes closeoutReceipt;
    uint256 closeoutType;
    uint256 providerWithdrawnAmount;
    uint128 openedAt;
    uint128 endsAt;
    uint128 closedAt;
    bool isActive;
    bool isDirectPaymentFromUser;
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] memory tags_
    ) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
}

/// @notice Fork PoC against the DEPLOYED LumerinDiamond on Base (Morpheus
/// bug bounty program, Appendix A). Fork pinned at block 58521896
/// (2026-11-17). No privileged accounts are used: every actor is a fresh
/// test wallet; the only state setup is `deal` (funding test wallets) and,
/// in the funding-shortfall test, zeroing the funding account's MOR balance
/// to simulate a dry treasury (state setup, not an attack step).
///
/// Finding: closeSession pays the provider from the funding account in the
/// same transaction as the user refund. If the funding account cannot pay,
/// the whole close reverts and the user's escrowed stake stays locked.
/// Only same-day early closes can exit through the dispute path; late and
/// multi-day closes have no escape.
contract MorpheusM01PoC is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant FUNDING = 0x5160C0311A95E0A1072FA85Df23712A7BA1cD4b1;
    uint256 constant FORK_BLOCK = 58521896;

    Vm.Wallet providerWallet;
    Vm.Wallet bobWallet;
    address provider;
    address bob;
    address alice;
    address modelOwner;
    bytes32 modelId;
    bytes32 bidId;
    uint256 constant PPS = 1e12; // 1e-6 MOR/s, within [1e10, 1e16]

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);

        providerWallet = vm.createWallet("provider");
        bobWallet = vm.createWallet("bob");
        provider = providerWallet.addr;
        bob = bobWallet.addr;
        alice = makeAddr("alice");
        modelOwner = makeAddr("modelOwner");

        // Deterministic time: noon UTC on the day after the fork block, so
        // open/close stay inside one UTC day unless a test warps across
        // midnight deliberately. (Warping forward only.)
        uint256 dayStart = (block.timestamp / 1 days) * 1 days;
        vm.warp(dayStart + 1 days + 12 hours);

        deal(MOR, provider, 200_000 ether);
        deal(MOR, modelOwner, 10_000 ether);
        deal(MOR, alice, 1_000_000 ether);
        deal(MOR, bob, 1_000_000 ether);
        vm.deal(provider, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(modelOwner, 10 ether);

        // Provider registers with the 50,000 MOR minimum stake.
        vm.startPrank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(provider, 50_000 ether, "provider.example:8080");
        vm.stopPrank();

        // Model registers with the 100 MOR minimum stake.
        bytes32 baseModelId = keccak256("base-model");
        vm.startPrank(modelOwner);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        string[] memory tags = new string[](1);
        tags[0] = "test";
        IDiamond(DIAMOND).modelRegister(modelOwner, baseModelId, bytes32(uint256(0x1234)), 0, 100 ether, "test-model", tags);
        vm.stopPrank();

        modelId = IDiamond(DIAMOND).getModelId(modelOwner, baseModelId);

        // Provider posts a bid (1.2 MOR fee).
        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, PPS);

        vm.startPrank(alice);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.stopPrank();
        vm.startPrank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.stopPrank();
    }

    // ---- helpers ----

    function _ethSign(Vm.Wallet memory wallet, bytes memory data) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(data)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Approval as the provider node builds it:
    /// abi.encode(bidId, chainId, user, timestamp), eth-signed by the provider.
    function _approval(bytes32 bidId_, address user_) internal view returns (bytes memory approval, bytes memory sig) {
        approval = abi.encode(bidId_, block.chainid, user_, uint128(block.timestamp));
        sig = _ethSign(providerWallet, approval);
    }

    function _open(address user, uint256 amount, bool direct, address approvalUser) internal returns (bytes32) {
        (bytes memory approval, bytes memory sig) = _approval(bidId, approvalUser);
        vm.prank(user);
        return IDiamond(DIAMOND).openSession(user, amount, direct, approval, sig);
    }

    /// @dev Receipt as the contract decodes it: (sessionId, chainId, timestamp, tps, ttft).
    function _receipt(bytes32 sessionId_, uint32 tps_, uint32 ttft_) internal view returns (bytes memory) {
        return abi.encode(sessionId_, block.chainid, uint128(block.timestamp), tps_, ttft_);
    }

    function _close(address user, bytes32 sessionId_, uint32 tps_, uint32 ttft_, Vm.Wallet memory signer) internal {
        bytes memory receipt = _receipt(sessionId_, tps_, ttft_);
        bytes memory sig = _ethSign(signer, receipt);
        vm.prank(user);
        IDiamond(DIAMOND).closeSession(receipt, sig);
    }

    // ---- M-01: an empty funding account bricks session closes (non-direct) ----
    // closeSession pays the provider from the funding account via transferFrom
    // in the same tx as the user refund; if the funding account cannot pay,
    // the whole close reverts and the user's stake stays locked.
    function test_DryFundingBricksLateClose() public {
        bytes32 sessionId = _open(bob, 1 ether, false, bob);
        Session memory s = IDiamond(DIAMOND).getSession(sessionId);
        uint256 bobBalBefore = IERC20(MOR).balanceOf(bob);
        uint256 diamondBalBefore = IERC20(MOR).balanceOf(DIAMOND);
        uint256 stake = s.stake;
        assertGt(stake, 0, "session escrowed a stake");

        vm.warp(s.endsAt + 1 hours);

        // Simulate a dry treasury: funding account holds 0 MOR.
        deal(MOR, FUNDING, 0);

        // Late close reverts: provider payment transferFrom fails.
        bytes memory receipt = _receipt(sessionId, 1000, 100);
        bytes memory sig = _ethSign(providerWallet, receipt);
        vm.prank(bob);
        (bool ok,) = DIAMOND.call(abi.encodeWithSelector(IDiamond.closeSession.selector, receipt, sig));
        assertFalse(ok, "close reverts while funding is dry");

        // The loss: the session stays open and the escrow stays locked.
        Session memory stuck = IDiamond(DIAMOND).getSession(sessionId);
        assertTrue(stuck.isActive, "session still active, cannot close");
        assertEq(IERC20(MOR).balanceOf(bob), bobBalBefore, "user refund blocked too");
        assertEq(IERC20(MOR).balanceOf(DIAMOND), diamondBalBefore, "escrowed stake still locked in the diamond");

        // Once the treasury is refilled, the same close succeeds.
        deal(MOR, FUNDING, 100_000 ether);
        vm.prank(bob);
        IDiamond(DIAMOND).closeSession(receipt, sig);
        Session memory closed = IDiamond(DIAMOND).getSession(sessionId);
        assertFalse(closed.isActive, "session closed after refill");
        assertGt(IERC20(MOR).balanceOf(bob), bobBalBefore, "user refunded after refill");
    }

    // ---- M-01 (supporting): the dispute-close escape only works for same-day early closes ----
    function test_DisputeEscapeOnlySameDayEarlyClose() public {
        bytes32 sessionId = _open(bob, 1 ether, false, bob);
        deal(MOR, FUNDING, 0);

        // Early close, same UTC day, with a self-signed (invalid-provider)
        // receipt: dispute path, provider on-hold == full reward, so the
        // provider payment is 0 and no funding-account transfer is needed.
        vm.warp(block.timestamp + 10 minutes);
        _close(bob, sessionId, 1000, 100, bobWallet); // signed by Bob, not provider
        Session memory s = IDiamond(DIAMOND).getSession(sessionId);
        assertEq(s.closeoutType, 1, "dispute close");
        assertFalse(s.isActive, "session closed despite dry funding");
    }
}
