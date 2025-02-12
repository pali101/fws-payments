// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Account {
        address owner;
        uint256 totalFunds;
        uint256 requiredLockedFunds;
        uint256 totalLockupRate;
        uint256 lastRateAccumulationEpoch;
        uint256 insufficientSinceEpoch;
        mapping(uint256 => uint256) railLockupAmounts; // railId => proportional locked amount
    }

    struct Rail {
        address from;
        address to;
        address token;
        address operator;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 lastSettled;
        uint256 unpaid;
    }

    mapping(address => mapping(address => Account)) public accounts;
    mapping(uint256 => Rail) public rails;
    uint256 public nextRailId;
    mapping(uint256 => bool) private railLocks;


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // TODO: Validate that this is used correctly
    modifier lockRail(uint256 railId) {
        require(!railLocks[railId], "Rail is locked");
        railLocks[railId] = true;
        _;
        railLocks[railId] = false;
    }

    // TODO Fix underwater account if not underwater anymore
    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Amount must be > 0");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        Account storage acct = accounts[token][to];
        if (acct.owner == address(0)) {
            acct.owner = to;
            acct.lastRateAccumulationEpoch = block.number;
        }
        acct.totalFunds += amount;
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        Account storage acct = accounts[token][msg.sender];
        require(acct.owner == msg.sender, "Not account owner");

        _accumulateElapsedRateLockup(token, msg.sender);

        uint256 available = acct.totalFunds > acct.requiredLockedFunds
            ? acct.totalFunds - acct.requiredLockedFunds
            : 0;

        require(amount <= available, "Insufficient unlocked funds");
        acct.totalFunds -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function createRail(
        address token,
        address from,
        address to,
        address operator
    ) external returns (uint256 railId) {
        require(token != address(0), "Invalid token");
        require(from != address(0) && to != address(0), "Invalid addresses");
        require(operator != address(0), "Invalid operator");

        railId = nextRailId++;
        rails[railId] = Rail({
            from: from,
            to: to,
            token: token,
            operator: operator,
            paymentRate: 0,
            lockupPeriod: 0,
            lockupFixed: 0,
            lastSettled: block.number,
            unpaid: 0
        });
    }

    function modifyRailLockup(
        uint256 railId,
        uint256 newLockupPeriod,
        uint256 newLockupFixed
    ) external lockRail(railId) {
        Rail storage r = rails[railId];
        require(msg.sender == r.operator, "Only operator");

        Account storage payer = accounts[r.token][r.from];
        _accumulateElapsedRateLockup(r.token, r.from);

        // Remove old lockup
        uint256 oldLock = (r.paymentRate * r.lockupPeriod) + r.lockupFixed;
        payer.requiredLockedFunds -= oldLock;

        // Add new lockup
        uint256 newLock = (r.paymentRate * newLockupPeriod) + newLockupFixed;
        payer.requiredLockedFunds += newLock;

        r.lockupPeriod = newLockupPeriod;
        r.lockupFixed = newLockupFixed;

        // TODO: What if account goes under water now ?
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 once
    ) external lockRail(railId) {
        Rail storage r = rails[railId];
        require(msg.sender == r.operator, "Only operator");

        settleRail(railId);
        Account storage payer = accounts[r.token][r.from];
        _accumulateElapsedRateLockup(r.token, r.from);

        // Update rate-based lockup
        payer.totalLockupRate = payer.totalLockupRate - r.paymentRate + newRate;
        payer.requiredLockedFunds = payer.requiredLockedFunds - (r.paymentRate * r.lockupPeriod) + (newRate * r.lockupPeriod);
        r.paymentRate = newRate;

        if (once <= 0) {
            return;
        }

        // Process one-time payment
        uint256 available = payer.totalFunds > payer.requiredLockedFunds
            ? payer.totalFunds - payer.requiredLockedFunds
            : 0;

        require(available >= once, "Insufficient funds for one-time payment");

        payer.totalFunds -= once;
        accounts[r.token][r.to].totalFunds += once;
    }

    function settleRail(uint256 railId) public lockRail(railId) {
        Rail storage r = rails[railId];
        require(r.from != address(0), "Rail does not exist");

        Account storage payer = accounts[r.token][r.from];
        _accumulateElapsedRateLockup(r.token, r.from);

        uint256 endBlock = payer.insufficientSinceEpoch > 0
            ? (payer.insufficientSinceEpoch < block.number ? payer.insufficientSinceEpoch : block.number)
            : block.number;

        if (endBlock <= r.lastSettled) return;

        uint256 elapsed = endBlock - r.lastSettled;
        r.lastSettled = endBlock;
        r.unpaid += r.paymentRate * elapsed;

        if (r.unpaid > 0) {
            // If account is insufficient, use this rail's proportional lockup
            uint256 available;
            if (payer.insufficientSinceEpoch > 0) {
                available = payer.railLockupAmounts[railId];
            } else {
                available = payer.totalFunds > payer.requiredLockedFunds
                    ? payer.totalFunds - payer.requiredLockedFunds
                    : 0;
            }

            uint256 payment = available > r.unpaid ? r.unpaid : available;
            if (payment > 0) {
                r.unpaid -= payment;
                payer.totalFunds -= payment;
                accounts[r.token][r.to].totalFunds += payment;
            }

            // If rail has unpaid amount and account wasn't marked insufficient yet
            if (r.unpaid > 0 && payer.insufficientSinceEpoch == 0) {
                payer.insufficientSinceEpoch = block.number;
                _calculateProportionalLockups(r.token, r.from);
            }
        }

        if (r.unpaid == 0 && payer.totalFunds >= payer.requiredLockedFunds) {
            payer.insufficientSinceEpoch = 0;
            payer.lastRateAccumulationEpoch = block.number;
        }
    }

    function _accumulateElapsedRateLockup(address token, address user) internal {
        Account storage acct = accounts[token][user];
        if (acct.owner == address(0)) return;

        uint256 blocksElapsed = block.number - acct.lastRateAccumulationEpoch;
        if (blocksElapsed > 0) {
            acct.requiredLockedFunds += acct.totalLockupRate * blocksElapsed;
            acct.lastRateAccumulationEpoch = block.number;
        }

        if (acct.totalFunds < acct.requiredLockedFunds && acct.insufficientSinceEpoch == 0) {
            acct.insufficientSinceEpoch = block.number;
            _calculateProportionalLockups(token, user);
        }
    }

    function _calculateProportionalLockups(address token, address user) internal {
        Account storage acct = accounts[token][user];
        uint256 totalLockup = 0;

        // First pass - calculate total lockup requirements
        for (uint256 i = 0; i < nextRailId; i++) {
            Rail storage r = rails[i];
            if (r.from == user && r.token == token) {
                totalLockup += (r.paymentRate * r.lockupPeriod) + r.lockupFixed;
            }
        }

        // Second pass - calculate proportional amounts
        if (totalLockup > 0) {
            for (uint256 i = 0; i < nextRailId; i++) {
                Rail storage r = rails[i];
                if (r.from == user && r.token == token) {
                    uint256 railLockup = (r.paymentRate * r.lockupPeriod) + r.lockupFixed;
                    acct.railLockupAmounts[i] = (acct.totalFunds * railLockup) / totalLockup;
                }
            }
        }
    }
}
