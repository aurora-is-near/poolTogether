pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/YieldLottery.sol";

contract YieldTest is Test {
    YieldLottery public lottery;
    address public constant aurora = 0x8BEc47865aDe3B172A928df8f990Bc7f2A3b9f79;
    address public constant jetStaking = 0xccc2b1aD21666A5847A804a73a41F904C4a4A0Ec;
    address public PLY = 0x09C9D464b58d96837f8d8b6f4d9fE4aD408d3A4f;
    address public BSTN = 0x9f1F933C660a1DC856F0E0Fe058435879c5CCEf0;
    address public TRI = 0xFa94348467f64D5A457F75F8bc40495D33c65aBB;
    address[] public streamTokens = [PLY, BSTN, TRI];
    address public user1 = address(11);
    address public user2 = address(22);
    address public user3 = address(33);
    uint256 public ticketPrice = 200;
    uint256[] public nums;

    function setUp() public {
        lottery = new YieldLottery(address(this));
        lottery.init(1 hours, ticketPrice, aurora, jetStaking, streamTokens);
    }

    function testFullFunctionality() public {
        buyTicket(user1, 20);
        buyTicket(user2, 20);
        buyTicket(user3, 20000);
        lottery.stake();
        vm.warp(block.timestamp + 10 days);
        lottery.concludeEpoch();
        vm.warp(block.timestamp + 2 days + 1);
        lottery.withdraw(0);
        claimTokens(user1, 0);
        claimTokens(user2, 0);
        claimTokens(user3, 0);

        console.log(IERC20(aurora).balanceOf(user1));
        console.log(IERC20(aurora).balanceOf(user2));
        console.log(IERC20(aurora).balanceOf(user3));

        assert(IERC20(aurora).balanceOf(user1) >= 200);

        // for (uint256 i; i < streamTokens.length;) {
        //     assert(IERC20(streamTokens[i]).balanceOf(user1) > 0);
        //     unchecked {
        //         i++;
        //     }
        // }
    }

    function buyTicket(address user, uint256 amount) public {
        deal(aurora, user, amount * ticketPrice);
        vm.startPrank(user);
        IERC20(aurora).approve(address(lottery), type(uint256).max);
        lottery.buyTickets(amount);
        vm.stopPrank();
    }

    function claimTokens(address user, uint256 epochId) public {
        vm.startPrank(user);
        lottery.claimTickets(epochId);
        vm.stopPrank();
    }
}
