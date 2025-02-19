// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./RateChangeQueue.sol";

interface IArbiter {
    struct ArbitrationResult {
        bool approved;
        uint256 modifiedAmount;
        uint256 settleUpto;
        string note;
    }

    function arbitratePayment(
        uint256 railId,
        uint256 proposedAmount,
        uint256 fromEpoch,
        uint256 toEpoch
    ) external returns (ArbitrationResult memory result);
}

contract Payments is Initializable, UUPSUpgradeable, OwnableUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using RateChangeQueue for RateChangeQueue.Queue;

    struct Account {
        address ownerAddress;
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        uint256 lockupLastSettledAt;
    }

    struct Rail {
        bool isActive;
        address token;
        address from;
        address to;
        address operator;
        address arbiter;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
    }

    struct OperatorApproval {
        bool isApproved;
        address arbitrer;
        uint256 rateAllowance;
        uint256 lockupAllowance;
    }

    // railId => RateChangeQueue
    mapping(uint256 => RateChangeQueue.Queue) public railRateChangeQueues;

    // Counter for generating unique rail IDs
    uint256 private _nextRailId;

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

    modifier validateRailActive(uint256 railId) {
        require(rails[railId].from != address(0), "rail does not exist");
        require(rails[railId].isActive, "rail is inactive");
        _;
    }

    modifier validateRailAccountsExist(uint256 railId) {
        Rail storage rail = rails[railId];
        require(rail.from != address(0), "rail does not exist");
        require(accounts[rail.token][rail.from].ownerAddress != address(0), "from account does not exist");
        require(accounts[rail.token][rail.to].ownerAddress != address(0), "to account does not exist");
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(rails[railId].operator == msg.sender, "only the rail operator can perform this action");
        _;
    }

    modifier onlyAccountOwner(address token) {
        address owner = accounts[token][msg.sender].ownerAddress;
        require(owner != address(0), "account does not exist");
        require(owner == msg.sender, "not account owner");
        _;
    }

    function approveOperator(
        address token,
        address operator,
        address arbiter,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) external onlyAccountOwner(token) {
        require(token != address(0), "token address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][msg.sender][operator];
        approval.arbitrer = arbiter;
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
        approval.isApproved = true;
    }

    // TODO: Revisit
    function terminateOperator(address operator) external  {
        require(operator != address(0), "operator address invalid");

        uint256[] memory railIds = clientOperatorRails[msg.sender][operator];
        for (uint256 i = 0; i < railIds.length; i++) {
            Rail storage rail = rails[railIds[i]];
            require(rail.from == msg.sender, "Not rail payer");
            if (!rail.isActive) {
                continue;
            }

            settleRail(railIds[i], block.number);

            Account storage account = accounts[rail.token][msg.sender];
            account.lockupCurrent -= rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
            account.lockupRate -= rail.paymentRate;

            rail.paymentRate = 0;
            rail.lockupFixed = 0;
            rail.lockupPeriod = 0;
            rail.isActive = false;

            OperatorApproval storage approval = operatorApprovals[rail.token][msg.sender][operator];
            approval.rateAllowance = 0;
            approval.lockupAllowance = 0;
            approval.isApproved = false;
        }
    }

    // TODO: implement
    function terminateRail() public {

    }

    function deposit(address token, address to, uint256 amount) external {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(amount > 0, "amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];
        if (account.ownerAddress == address(0)) {
            account.ownerAddress = to;
        }

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;

        // settle account lockup now that we have more funds
        settleAccountLockup(account);
    }

    function withdraw(address token, uint256 amount) external onlyAccountOwner(token) nonReentrant {
        Account storage acct = accounts[token][msg.sender];

        (bool funded, uint256 settleEpoch) = settleAccountLockup(acct);
        require(funded && settleEpoch == block.number, "insufficient funds");

        uint256 available = acct.funds > acct.lockupCurrent
            ? acct.funds - acct.lockupCurrent
            : 0;

        require(amount <= available, "insufficient unlocked funds for withdrawal");
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
        require(token != address(0), "token address cannot be zero");
        require(from != address(0), "from address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval memory approval = operatorApprovals[token][from][operator];
        require(approval.isApproved, "operator not approved");

        Account storage toAccount = accounts[token][to];
        require(toAccount.ownerAddress != address(0), "to account does not exist");
        require(toAccount.funds > 0, "to account has no funds");

        Account storage fromAccount = accounts[token][from];
        require(fromAccount.ownerAddress != address(0), "from account does not exist");
        require(fromAccount.funds > 0, "from account has no funds");

        if (approval.arbitrer != address(0)) {
            require(arbiter == approval.arbitrer, "arbiter mismatch");
        }

        uint256 railId = _nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.isActive = true;
        rail.settledUpTo = block.number;

        clientOperatorRails[from][operator].push(railId);
        return railId;
    }

    function modifyRailLockup(
            uint256 railId,
            uint256 period,
            uint256 lockupFixed
        ) external validateRailActive(railId) validateRailAccountsExist(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];

        Account storage payer = accounts[rail.token][rail.from];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "operator not approved");

        // settle account lockup and if account is not funded upto to the current epoch; revert
        (bool funded, uint256 settleEpoch) = settleAccountLockup(payer);
        require(funded && settleEpoch == block.number, "cannot modify lockup as client does not have enough funds for current settlement");

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed + (rail.paymentRate * rail.lockupPeriod);
        uint256 newLockup = lockupFixed + (rail.paymentRate * period);

        // assert that operator allowance is respected
        require(newLockup <= oldLockup + approval.lockupAllowance, "exceeds operator lockup allowance");
        approval.lockupAllowance = approval.lockupAllowance + oldLockup - newLockup;

        // Update payer's lockup
        require(payer.lockupCurrent >= oldLockup, "payer lockup lockup_current cannot be less than old lockup");
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;

        require(payer.lockupCurrent <= payer.funds, "payer lockup_current cannot be greater than funds");
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    )
        external
        validateRailActive(railId)
        validateRailAccountsExist(railId)
        onlyRailOperator(railId)
        returns (uint256 deficit)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "Operator not approved");

        // Settle the payer's lockup.
        // If we're changing the rate, we require full settlement.
        (bool lockupSettled, uint256 settledEpoch) = settleAccountLockup(payer);
        if (newRate != rail.paymentRate) {
            require(lockupSettled && settledEpoch == block.number, "lockup not fully settled; cannot change rate");
        }

        // Save the current rate for computing lockup deltas.
        uint256 oldRate = rail.paymentRate;

        // --- Operator Approval Checks ---
        validateAndModifyRateChangeApproval(rail, approval, oldRate, newRate, oneTimePayment);

        // --- Settlement Prior to Rate Change ---
        // If there is no arbiter, settle the rail immediately.
        if (rail.arbiter == address(0)) {
            (, uint256 settledUntil, ) = settleRail(railId, block.number);
            require(settledUntil == block.number, "not able to settle rail at current epoch");
        } else {
            railRateChangeQueues[railId].enqueue(rail.paymentRate, block.number);
        }


        payer.lockupRate = payer.lockupRate - oldRate + newRate;
        // Update the payer's current locked funds:
        // Remove the old continuous lockup and also subtract the one-time payment,
        // then add the new continuous lockup requirement.
        payer.lockupCurrent = payer.lockupCurrent - (oldRate * rail.lockupPeriod) + (newRate * rail.lockupPeriod) - oneTimePayment;

        rail.paymentRate = newRate;
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;

        // --- Process the One-Time Payment ---
        processOneTimePayment(payer, payee, oneTimePayment);

        require(rail.lockupFixed >= 0, "rail lockupFixed must be non-negative");
        require(payer.lockupCurrent >= 0, "payer lockupCurrent must be non-negative");
        require(payer.lockupCurrent <= payer.funds, "payer lockup cannot exceed funds");

        return 0;
    }

    function processOneTimePayment(
        Account storage payer,
        Account storage payee,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment > 0) {
            require(payer.funds >= oneTimePayment, "insufficient funds for one-time payment");
            payer.funds -= oneTimePayment;
            payee.funds += oneTimePayment;
        }
    }

    function validateAndModifyRateChangeApproval(
        Rail storage rail,
        OperatorApproval storage approval,
        uint256 oldRate,
        uint256 newRate,
        uint256 oneTimePayment
    ) internal {
        require(oneTimePayment <= rail.lockupFixed, "one-time payment exceeds rail fixed lockup");

        uint256 oldLockup = (oldRate * rail.lockupPeriod) + rail.lockupFixed;
        uint256 newLockup = (newRate * rail.lockupPeriod) + (rail.lockupFixed - oneTimePayment);

        // Check that new total lockup + one time payment is within allowance
        require(newLockup + oneTimePayment <= oldLockup + approval.lockupAllowance, "exceeds operator lockup allowance");
        // Adjust the operator's available lockup allowance.
        approval.lockupAllowance = approval.lockupAllowance + oldLockup - (newLockup + oneTimePayment);
        require(newRate <= approval.rateAllowance, "new rate exceeds operator rate allowance");
    }


    function updateRailArbiter(uint256 railId, address newArbiter) external validateRailActive(railId) onlyRailOperator(railId) {
        Rail storage rail = rails[railId];
        OperatorApproval storage approval = operatorApprovals[rail.token][rail.from][rail.operator];
        require(approval.isApproved, "operator not approved");
        if (approval.arbitrer != address(0)) {
            require(newArbiter == approval.arbitrer, "arbiter mismatch");
        }
        // Update the arbiter
        rail.arbiter = newArbiter;
    }


    function settleRail(uint256 railId, uint256 untilEpoch)
        public
        validateRailActive(railId)
        validateRailAccountsExist(railId)
        returns (
            uint256 totalSettledAmount,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        require(untilEpoch <= block.number, "failed to settle: cannot settle future epochs");
        // Get the rail and the involved accounts.
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        settleAccountLockup(payer);

        uint256 settlementTargetEpoch = min(untilEpoch, payer.lockupLastSettledAt + rail.lockupPeriod);

        // Begin settlement from the last settled epoch.
        uint256 currentSettlementEpoch = rail.settledUpTo;
        uint256 currentRate = rail.paymentRate;
        totalSettledAmount = 0;

        // Use the rail's rate–change queue.
        RateChangeQueue.Queue storage rateQueue = railRateChangeQueues[railId];

        // If there are no queued rate changes, settle the entire segment in one shot.
        if (rateQueue.isEmpty()) {
            (totalSettledAmount, finalSettledEpoch, note) = _settleSegment(
                railId,
                rail,
                currentSettlementEpoch,
                settlementTargetEpoch,
                currentRate
            );
        } else {
            // Otherwise, settle the rail in segments (each up to the next rate–change boundary).
            (totalSettledAmount, finalSettledEpoch, note) = _settleWithRateChanges(
                railId,
                rail,
                rateQueue,
                currentRate,
                currentSettlementEpoch,
                settlementTargetEpoch
            );
        }

        // Update account balances.
        payer.funds -= totalSettledAmount;
        payee.funds += totalSettledAmount;
        require(payer.lockupCurrent >= totalSettledAmount, "Insufficient lockup funds");
        payer.lockupCurrent -= totalSettledAmount;

        // Record the new settlement epoch on the rail.
        rail.settledUpTo = finalSettledEpoch;

        require(payer.lockupCurrent <= payer.funds, "insufficient funds");

        return (totalSettledAmount, finalSettledEpoch, note);
    }

    function _settleSegment(
        uint256 railId,
        Rail storage rail,
        uint256 segmentStart,
        uint256 segmentEnd,
        uint256 rate
    ) internal returns (uint256 settledAmount, uint256 settledUntil, string memory note) {
        // Calculate the intended payment for the entire segment.
        uint256 duration = segmentEnd - segmentStart;
        settledAmount = rate * duration;
        settledUntil = segmentEnd;

        if (rail.arbiter != address(0)) {
            // Call the external arbitrator.
            IArbiter arbiter = IArbiter(rail.arbiter);
            IArbiter.ArbitrationResult memory arbResult = arbiter.arbitratePayment(
                railId,
                settledAmount,
                segmentStart,
                segmentEnd
            );
            require(arbResult.approved, "arbitrer refused payment");

            require(arbResult.settleUpto <= segmentEnd, "failed to settle: arbiter settled beyond segment end");
            require(
                arbResult.modifiedAmount <= rate * (arbResult.settleUpto - segmentStart),
                "failed to settle: arbiter modified amount exceeds maximum for settled duration"
            );
            // Do not settle past the segment end.
            settledUntil = arbResult.settleUpto;
            settledAmount = arbResult.modifiedAmount;
            note = arbResult.note;
        }

        // If no progress is made, revert.
        require(settledUntil > segmentStart, "no progress made in settlement");

        return (settledAmount, settledUntil, note);
    }

    function _settleWithRateChanges(
        uint256 railId,
        Rail storage rail,
        RateChangeQueue.Queue storage rateQueue,
        uint256 currentRate,
        uint256 startEpoch,
        uint256 targetEpoch
    ) internal returns (uint256 totalSettled, uint256 finalEpoch, string memory note) {
        totalSettled = 0;
        uint256 currentEpoch = startEpoch;

        while (currentEpoch < targetEpoch) {
            // Determine the next boundary: either the next queued rate–change or the targetEpoch.
            uint256 nextBoundary = targetEpoch;
            uint256 segmentRate = currentRate;
            if (!rateQueue.isEmpty()) {
                RateChangeQueue.RateChange memory nextChange = rateQueue.peek();
                if (nextChange.untilEpoch > currentEpoch && nextChange.untilEpoch <= targetEpoch) {
                    nextBoundary = nextChange.untilEpoch;
                    segmentRate = nextChange.rate;
                }
            }

            // Settle the segment from currentEpoch up to nextBoundary.
            (uint256 segmentAmount, uint256 segmentSettledEpoch, string memory tempNote) = _settleSegment(
                railId,
                rail,
                currentEpoch,
                nextBoundary,
                segmentRate
            );


            require(segmentSettledEpoch <= nextBoundary, "segment settled epoch exceeds boundary");

            // Short circuit and return if _settleSegment returns an epoch less than what we sent it
            if (segmentSettledEpoch < nextBoundary) {
                return (totalSettled + segmentAmount, segmentSettledEpoch, tempNote);
            }

            totalSettled += segmentAmount;
            currentEpoch = segmentSettledEpoch;
            rateQueue.dequeue();
        }


        finalEpoch = currentEpoch;
        return (totalSettled, finalEpoch, "");
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    function settleAccountLockup(Account storage account) internal returns (bool fullySettled, uint256 settledUpto) {
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - account.lockupLastSettledAt;

        if (elapsedTime <= 0) {
            return (true, account.lockupLastSettledAt);
        }

        if (account.lockupRate == 0) {
            account.lockupLastSettledAt = currentEpoch;
            return (true, currentEpoch);
        }

        uint256 additionalLockup = account.lockupRate * elapsedTime;

        if (account.funds >= account.lockupCurrent + additionalLockup) {
            // If sufficient, apply full lockup
            account.lockupCurrent += additionalLockup;
            account.lockupLastSettledAt = currentEpoch;
            return (true, currentEpoch);
        } else {
            // If insufficient, calculate the fractional epoch where funds became insufficient
            uint256 availableFunds = account.funds > account.lockupCurrent ? account.funds - account.lockupCurrent : 0;

            if (availableFunds == 0) {
                return (false, account.lockupLastSettledAt);
            }

            // Round down to the nearest whole epoch
            uint256 fractionalEpochs = availableFunds / account.lockupRate;
            settledUpto = account.lockupLastSettledAt + fractionalEpochs;

            // Apply lockup up to this point
            account.lockupCurrent += account.lockupRate * fractionalEpochs;
            account.lockupLastSettledAt = settledUpto;
            return (false, settledUpto);
        }
    }
}