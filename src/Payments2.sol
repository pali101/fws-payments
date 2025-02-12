// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// TODO: Figure out how to use this
interface IArbiter {
    struct ArbitrationResult {
        bool payInFull;      // true to accept the payment in full
        uint256 penalty;     // amount to subtract from settled payment
        uint256 pauseAfter;  // latest epoch to settle
    }

    function arbitratePayment(
        uint256 railId,
        address token,
        address from,
        address to,
        uint256 amount,
        uint256 lastSettledAt,
        uint256 epochsSinceLastSettlement,
        uint256 operatorId
    ) external returns (ArbitrationResult memory);
}

contract Payments2 is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Account {
        address owner;           // allowed to operate on the account
        uint256 funds;          // amount of funds in the account
        uint256 lockupBase;     // locked funds (always non-negative)
        uint256 lockupRate;     // rate at which funds are locked (always non-negative)
        uint256 lockupStart;    // epoch at which the lockup rate begins to apply
        uint256 lockupInsufficientSince;  // epoch when account stopped having enough locked funds
    }

    struct Rail {
        address token;          // token being used for payment
        address from;           // payer address
        address to;            // payee address
        address operator;      // operator address (typically the market contract)
        address arbiter;       // optional arbiter address for payment validation
        uint256 paymentRate;   // rate at which this rail pays the payee
        uint256 lockupPeriod;  // time into the future up-to-which funds will always be locked
        uint256 lockupFixed;   // fixed amount of locked funds
        uint256 lastSettledAt; // epoch at which the rail was last settled
    }

    struct OperatorApproval {
        uint256 rate;    // max rate at which operator can establish payments
        uint256 base;    // amount operator is allowed to spend outside of rate
    }

    // State variables
    mapping(address => mapping(address => Account)) public accounts;  // token => owner => Account
    mapping(uint256 => Rail) public rails;  // railId => Rail
    uint256 private nextRailId;  // Counter for generating unique rail IDs
    mapping(address => mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;  // token => account => operator => Approval


    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // TODO: Handle unpaid debts
    function deposit(address token, address to, uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");
        require(to != address(0), "Invalid recipient");
        require(token != address(0), "Invalid token address");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];
        if (account.owner == address(0)) {
            account.owner = to;
        }

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        Account storage acct = accounts[token][msg.sender];
        require(acct.owner != address(0), "Account does not exist");
        require(acct.owner == msg.sender, "Not account owner");

        settleAccountLockup(acct);

        uint256 available = acct.funds > acct.lockupBase
            ? acct.funds - acct.lockupBase
            : 0;

        require(amount <= available, "Insufficient unlocked funds");
        acct.funds -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function createRail(
        address token,
        address from,
        address to,
        address operator,
        address arbiter
    ) external returns (uint256) {
        require(token != address(0), "Invalid token");
        require(from != address(0), "Invalid from address");
        require(to != address(0), "Invalid to address");
        require(operator != address(0), "Invalid operator");

        Account storage toAccount = accounts[token][to];
        require(toAccount.owner != address(0), "To account does not exist");
        Account storage fromAccount = accounts[token][from];
        require(fromAccount.owner != address(0), "From account does not exist");
        require(fromAccount.funds > 0, "From account has no funds");
        require(toAccount.funds > 0, "To account has no funds");

        uint256 railId = nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.lastSettledAt = block.number;

        rails[railId] = rail;
        return railId;
    }

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 newFixed
    ) external returns (uint256) {
        Rail storage rail = rails[railId];
        require(rail.operator == msg.sender, "Only operator can modify rail lockup");
        require(rails[railId].token != address(0), "Rail does not exist");

        Account storage payer = accounts[rail.token][rail.from];

        settleAccountLockup(payer);

        // Update payer lockup base
        payer.lockupBase -= rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
        payer.lockupBase += newFixed + (rail.paymentRate * period);

        // Update rail lockup values
        rail.lockupPeriod = period;
        rail.lockupFixed = newFixed;

        // Calculate deficit if any
        if (payer.funds < payer.lockupBase) {
            return payer.lockupBase - payer.funds;
        }
        return 0;
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 rate,
        uint256 once
    ) external returns (uint256) {
        Rail storage rail = rails[railId];
        require(rail.operator == msg.sender, "Only operator can modify rail payment");
        require(rail.token != address(0), "Rail does not exist");

        // Settle the rail first
        settleRail(railId);

        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Update lockup
        settleAccountLockup(payer);
        payer.lockupRate -= rail.paymentRate;
        payer.lockupRate += rate;
        payer.lockupBase -= rail.paymentRate * rail.lockupPeriod;
        payer.lockupBase += rate * rail.lockupPeriod;

        // Update rail payment rate
        rail.paymentRate = rate;

        // Process one-time payment if specified
        if (once > 0) {
            require(payer.funds >= once, "Insufficient funds for one-time payment");
            payer.funds -= once;
            payee.funds += once;
        }

        // Calculate and return deficit if any
        if (payer.funds < payer.lockupBase) {
            return payer.lockupBase - payer.funds;
        }
        return 0;
    }




    // ---- Functions below all internal ----
    function settleRail(uint256 railId) public {
        Rail storage rail = rails[railId];
        require(rail.token != address(0), "Rail does not exist");

        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - rail.lastSettledAt;
        if (elapsedTime == 0) return;

        Account storage fromAccount = accounts[rail.token][rail.from];
        Account storage toAccount = accounts[rail.token][rail.to];
        require(fromAccount.owner != address(0), "From account does not exist");
        require(toAccount.owner != address(0), "To account does not exist");

        // Settle lockups before processing payment
        settleAccountLockup(fromAccount);

        uint256 paymentAmount = rail.paymentRate * elapsedTime;
        uint256 actualPayment = paymentAmount;

        // Arbiter validation if exists
        if (rail.arbiter != address(0)) {
            // TODO: Call arbiter and adjust actualPayment based on response
            // IArbiter(rail.arbiter).validatePayment(railId, paymentAmount);
        }

        // Check available funds
        if (fromAccount.funds < actualPayment) {
            actualPayment = fromAccount.funds;
            // TODO What about the remaining amount?
        }

        // Process payment
        if (actualPayment > 0) {
            // Update balances
            fromAccount.funds -= actualPayment;
            toAccount.funds += actualPayment;

            // Update lockup
            // Reduce lockup by the settled amount
            fromAccount.lockupBase = fromAccount.lockupBase > actualPayment ?
                fromAccount.lockupBase - actualPayment : 0;

            // Maintain future lockup requirements
            uint256 futureLockup = rail.paymentRate * rail.lockupPeriod + rail.lockupFixed;
            fromAccount.lockupBase += futureLockup;
        }

        // Update last settlement time
        rail.lastSettledAt = currentEpoch;
    }

    function settleAccountLockup(Account storage acct) internal {
        uint256 currentEpoch = block.number;

        // Convert rate-based lockup to fixed base
        acct.lockupBase += acct.lockupRate * (currentEpoch - acct.lockupStart);
        acct.lockupStart = currentEpoch;
    }
}
