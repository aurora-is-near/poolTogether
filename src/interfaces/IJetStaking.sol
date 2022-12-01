pragma solidity ^0.8.13;

interface IJetStaking {
    function stake(uint256 amount) external;
    function moveRewardsToPending(uint256 streamId) external;
    function moveAllRewardsToPending() external;
    function withdraw(uint256 streamId) external;
    function withdrawAll() external;
    function getUserShares(address account) external view returns (uint256);
    function getTotalAmountOfStakedAurora() external view returns (uint256);
    function totalAuroraShares() external view returns (uint256);
    function unstakeAll() external;
}
