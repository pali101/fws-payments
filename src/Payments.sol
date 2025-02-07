// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct OperatorApproval {
       uint256 maxAmount;
       uint256 period;
       uint256 lastReset;
       uint256 usedInCurrentPeriod;
    }

    // tokenBalances[token][owner] = amount
    mapping(address => mapping(address => uint256)) public tokenBalances;

    // operatorApprovals[owner][token][operator] = OperatorApproval
    mapping(address =>mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "Invalid token address");
        require(to != address(0), "Invalid recipient address");
        require(amount != 0, "Amount must be greater than zero");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenBalances[token][to] += amount;
    }

    function approve(address token, address operator, uint256 maxAmount, uint256 period) external {
        require(token != address(0), "Invalid token address");
        require(operator != address(0), "Invalid operator address");
        require(operator != msg.sender, "Cannot approve self as operator");
        require(maxAmount > 0 || (maxAmount == 0 && period == 0), "Invalid max amount");
        require(period >= 0, "Invalid period");

        operatorApprovals[msg.sender][token][operator] = OperatorApproval({
            maxAmount: maxAmount,
            period: period,
            lastReset: block.timestamp,
            usedInCurrentPeriod: 0
        });
    }
}
