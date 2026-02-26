// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBubbleToken {
    function mint(address to, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function efficiencyCredits(address account) external view returns (uint256);
    function consumeCredits(address player, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function setGameController(address controller) external;
    function setAuthorized(address account, bool status) external;
}
