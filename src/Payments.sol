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
        address owner;           // allowed to operate on the account
        uint256 funds;          // amount of funds in the account
        uint256 lockupBase;     // locked funds (always non-negative)
        uint256 lockupRate;     // rate at which funds are locked (always non-negative)
        bool hasLockupStarted;
        uint256 lockupStart;    // epoch at which the lockup rate begins to apply
        uint256 lockupInsufficientSince;  // epoch when account stopped having enough locked funds
    }

    struct Rail {
        bool isRateSet;
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
        bool isApproved;
        address arbitrer; // optional arbitrer address approved for payment validation by the client
        uint256 maxRate;    // max rate at which operator can establish payments
        uint256 maxBase;    // amount operator is allowed to spend outside of rate
        uint256 rate_used;
        uint256 base_used;
    }

    // Counter for generating unique rail IDs
    uint256 private nextRailId;

    // token => owner => Account
    mapping(address => mapping(address => Account)) public accounts;
    // railId => Rail
    mapping(uint256 => Rail) public rails;
    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval))) public operatorApprovals;
    // client => operator => railIds
    mapping(address => mapping(address => uint256[])) public clientOperatorRails;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier validateRailExists(uint256 railId) {
        require(rails[railId].from != address(0), "Rail does not exist");
        _;
    }

    modifier validateRailAccountsExist(uint256 railId) {
        Rail storage rail = rails[railId];
        require(rail.from != address(0), "Rail does not exist");
        require(accounts[rail.token][rail.from].owner != address(0), "From account does not exist");
        require(accounts[rail.token][rail.to].owner != address(0), "To account does not exist");
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(rails[railId].operator == msg.sender, "Only the rail operator can perform this action");
        _;
    }

    modifier onlyAccountOwner(address token) {
        address owner = accounts[token][msg.sender].owner;
        require(owner != address(0), "Account does not exist");
        require(owner == msg.sender, "Not account owner");
        _;
    }

    /// @notice Approves or modifies approval for an operator to create and manage payment rails
    /// @dev This sets approval limits for new rails and rail modifications going forward.
    /// When reducing approvals, existing rails continue operating under their original
    /// terms (i.e. existing rails are grandfathered).
    /// However, any modifications to existing rails must fit within these new approval limits.
    /// @dev Approval tracking works as follows:
    /// - New rails check against current maxRate/maxBase minus rate_used/base_used
    /// - Rail modifications (e.g. rate increases) also check against these current limits
    /// - Existing unmodified rails continue with their original terms
    /// This allows users to reduce exposure while honoring existing commitments
    /// @param token The ERC20 token address this approval is for
    /// @param operator The address being approved to create/modify rails
    /// @param arbiter Optional address that can validate payments (0x0 for none)
    /// @param maxRate Maximum rate at which the sum of all rails operated by this operator can pay out.
    /// Payments made via rail payment rates count against this limit. Unused rate does not accumulate.
    /// @param maxBase Maximum amount operator can spend outside of rate-based payments. This covers:
    /// 1) Lockup amounts (sum of rail.rate * rail.lockup_period + rail.lockup_fixed for all operator rails).
    /// Lockup modifications count against but do not modify base.
    /// 2) One-time payments made via ModifyRailPayment's 'once' parameter.
    function approveOperator(
        address token,
        address operator,
        address arbiter,
        uint256 maxRate,
        uint256 maxBase
    ) external onlyAccountOwner(token) {
        require(token != address(0), "Token address cannot be zero");
        require(operator != address(0), "Operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][msg.sender][operator];
        approval.arbitrer = arbiter;
        approval.maxRate = maxRate;
        approval.maxBase = maxBase;
        approval.isApproved = true;
    }

    // TODO: Debt handling
    function terminateOperator(address operator) external  {
        require(operator != address(0), "operator address invalid");

        uint256[] storage railIds = clientOperatorRails[msg.sender][operator];
        for (uint256 i = 0; i < railIds.length; i++) {
            Rail storage rail = rails[railIds[i]];
            require(rail.from == msg.sender, "Not rail owner");

            settleRail(railIds[i]);

            Account storage account = accounts[rail.token][msg.sender];
            account.lockupBase -= rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
            account.lockupRate -= rail.paymentRate;

            rail.paymentRate = 0;
            rail.lockupFixed = 0;
            rail.lockupPeriod = 0;

            OperatorApproval storage approval = operatorApprovals[rail.token][msg.sender][operator];
            approval.maxRate = 0;
            approval.maxBase = 0;
            approval.rate_used = 0;
            approval.base_used = 0;
            approval.isApproved = false;
        }
    }

    // TODO: Debt payment ?
    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "Token address cannot be zero");
        require(to != address(0), "To address cannot be zero");
        require(amount > 0, "Amount must be greater than 0");

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

    /// @notice Allows an account owner to withdraw funds from their account.
    /// @dev This function settles the account's lockup before calculating available funds.
    /// @dev Withdrawal is only possible if the account has sufficient unlocked funds after accounting
    /// for lockup.
    /// @dev The available balance for withdrawal is calculated as:
    ///      max(0, account.funds - account.lockupBase)
    /// @dev If the requested amount exceeds available unlocked funds, the transaction will revert
    /// @param token The address of the ERC20 token to withdraw
    /// @param amount The amount of tokens to withdraw
    function withdraw(address token, uint256 amount) external onlyAccountOwner(token) nonReentrant {
        Account storage acct = accounts[token][msg.sender];

        applyAccumulatedRateLockup(acct);

        uint256 available = acct.funds > acct.lockupBase
            ? acct.funds - acct.lockupBase
            : 0;

        require(amount <= available, "Insufficient unlocked funds for withdrawal");
        acct.funds -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Creates a new payment rail between a payer and payee, initiated by an approved operator.
    /// @dev This function checks that:
    /// 1. The token, from, to, and operator addresses are all valid (non-zero).
    /// 2. Both the payer (from) and payee (to) have existing accounts for the given token.
    /// 3. The payer account has a non-zero balance.
    /// 4. The operator has been pre-approved by the payer to create rails on their behalf.
    /// 5. If the operator approval specifies an arbiter, it must match the one passed to this function.
    /// @param token The ERC20 token to use for payments on this rail.
    /// @param from The payer account.
    /// @param to The payee account.
    /// @param operator The account creating and managing this rail, must be pre-approved by the payer.
    /// @param arbiter An optional account that can validate payments, must match operator approval if set.
    /// @return railId The unique ID of the newly created payment rail.
    function createRail(
        address token,
        address from,
        address to,
        address operator,
        address arbiter
    ) external returns (uint256) {
        require(token != address(0), "Token address cannot be zero");
        require(from != address(0), "From address cannot be zero");
        require(to != address(0), "To address cannot be zero");
        require(operator != address(0), "Operator address cannot be zero");

        Account storage toAccount = accounts[token][to];
        require(toAccount.owner != address(0), "To account does not exist");
        Account storage fromAccount = accounts[token][from];
        require(fromAccount.owner != address(0), "From account does not exist");
        require(fromAccount.funds > 0, "From account has no funds");
        require(toAccount.funds > 0, "To account has no funds");

        OperatorApproval storage approval = operatorApprovals[token][from][operator];
        require(approval.isApproved, "Operator not approved");

        if (approval.arbitrer != address(0)) {
            require(arbiter == approval.arbitrer, "Arbiter mismatch");
        }

        uint256 railId = nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.lastSettledAt = block.number;

        rails[railId] = rail;
        clientOperatorRails[from][operator].push(railId);
        return railId;
    }

    function modifyRailLockup(
            uint256 railId,
            uint256 period,
            uint256 fixedLockup
        ) external validateRailExists(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) returns (uint256) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        applyAccumulatedRateLockup(payer);

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
        uint256 newLockup = fixedLockup + (rail.paymentRate * period);

        require(approval.base_used >= oldLockup, "base used cannot be less than oldLockup");
        require(approval.base_used - oldLockup + newLockup <= approval.maxBase, "Exceeds operator base approval");
        require(payer.lockupBase >= oldLockup, "payer lockup base cannot be less than oldLockup");

        // Update base used
        approval.base_used = approval.base_used - oldLockup + newLockup;

        // Update payer's lockup base
        payer.lockupBase = payer.lockupBase - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = fixedLockup;

        // Calculate and return deficit if any
        if (payer.funds < payer.lockupBase) {
            return payer.lockupBase - payer.funds;
        }
        return 0;
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 rate,
        uint256 once
    ) external validateRailExists(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) returns (uint256) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        // Settle the rail before modifying payment
        // This ensures that all past payments are accounted for before changing the rate
        settleRail(railId);

        // Calculate the change in rate
        uint256 oldRate = rail.paymentRate;

        // Check if the new rate exceeds the operator's approval
        require(approval.rate_used - oldRate + rate <= approval.maxRate, "Exceeds operator rate approval");

        // Update the operator's used rate
        approval.rate_used = approval.rate_used - oldRate + rate;

        // Update rail payment rate
        rail.paymentRate = rate;


        // Handle one-time payment if specified
        if (once > 0) {
            require(approval.base_used + once <= approval.maxBase, "Exceeds operator base approval");
            require(payer.funds >= once, "Insufficient funds for one-time payment");

            payer.funds -= once;
            payee.funds += once;

            // Update operator's used base
            approval.base_used += once;
        }

        // Update payer's lockup rate and base
        payer.lockupBase = payer.lockupBase - (oldRate * rail.lockupPeriod) + (rate * rail.lockupPeriod);
        payer.lockupRate = payer.lockupRate - oldRate + rate;

        // Init hasLockupStarted flag and lockupStart for the first rail with non-zero rate
        if (rate > 0 && !payer.hasLockupStarted) {
            payer.hasLockupStarted = true;
            payer.lockupStart = block.number;
        }

        // Init lastSettledAt and isRateSet flag when rate is first set for rail
        if (rate > 0 && !rail.isRateSet) {
            rail.isRateSet = true;
            rail.lastSettledAt = block.number;
        }

        return 0; // No deficit as we assumed user has enough funds
    }


    function updateRailArbiter(uint256 railId, address newArbiter) external validateRailExists(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];

        // Update the arbiter
        rail.arbiter = newArbiter;
    }

    // TODO: anybody can call this -> is that okay ?
    function settleRailBatch(uint256[] calldata railId) public {
        for (uint256 i = 0; i < railId.length; i++) {
            settleRail(railId[i]);
        }
    }

    // TODO: anybody can call this -> is that okay ?
    function settleRail(uint256 railId) public validateRailExists(railId) validateRailAccountsExist(railId) {
        Rail storage rail = rails[railId];
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - rail.lastSettledAt;

        if (elapsedTime == 0) return;

        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Apply accumulated rate lockup for payer
        applyAccumulatedRateLockup(payer);

        // Calculate payment amount
        uint256 paymentAmount = rail.paymentRate * elapsedTime;

        // Update balances
        payer.funds -= paymentAmount;
        payee.funds += paymentAmount;

        // Update last settlement time
        rail.lastSettledAt = currentEpoch;

        // Adjust lockup base for payer
        payer.lockupBase -= paymentAmount;
    }

    // ---- Functions below are all private/internal ----

    /**
     * @dev Applies the accumulated rate-based lockup to the account's base lockup.
     * @notice This function converts the rate-based lockup that has accumulated
     * since the last settlement into a fixed base amount.
     *
     * @dev It updates the `lockupBase` to include the additional funds that should
     * be locked based on the `lockupRate` and the time elapsed since the last settlement.
     * Future lockup needs are handled separately when creating or modifying rails.
     *
     * @param acct The Account struct to apply the accumulated rate lockup for
     */
    function applyAccumulatedRateLockup(Account storage acct) internal {
        uint256 currentEpoch = block.number;

        // Convert rate-based lockup accumulation to fixed base
        acct.lockupBase += acct.lockupRate * (currentEpoch - acct.lockupStart);
        acct.lockupStart = currentEpoch;
    }
}
