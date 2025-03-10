// SPDX-License-Identifier: MIT
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
        uint256 modifiedAmount;
        // The epoch up to and including which settlement should occur.
        // This is used to indicate how far the arbitration has settled the payment.
        uint256 settleUpto;
        string note;
    }

    function arbitratePayment(
        uint256 railId,
        uint256 proposedAmount,
        // the epoch up to and including which the rail has already been settled
        uint256 fromEpoch,
        // the epoch up to which arbitration is requested; payment will be arbitrated for (toEpoch - fromEpoch) epochs
        uint256 toEpoch
    ) external returns (ArbitrationResult memory result);
}

contract Payments is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using RateChangeQueue for RateChangeQueue.Queue;

    struct Account {
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        // The epoch up to and including which lockup has been settled for the account
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
        // The epoch up to and including which this rail has been settled
        uint256 settledUpTo;
        RateChangeQueue.Queue rateChangeQueue;
        bool isLocked; // Indicates if the rail is currently being modified
        uint256 terminationEpoch; // Epoch at which the rail was terminated (0 if not terminated)
    }

    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage; // Track actual usage for rate
        uint256 lockupUsage; // Track actual usage for lockup
    }

    struct RailPaymentCapability {
        bool terminated;
        bool zeroRate;
        uint256 guaranteedFutureEpochs;
    }

    // Counter for generating unique rail IDs
    uint256 private _nextRailId;

    // token => owner => Account
    mapping(address => mapping(address => Account)) public accounts;

    // railId => Rail
    mapping(uint256 => Rail) internal rails;

    // token => client => operator => Approval
    mapping(address => mapping(address => mapping(address => OperatorApproval)))
        public operatorApprovals;

    // client => operator => railIds
    mapping(address => mapping(address => uint256[]))
        public clientOperatorRails;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    modifier validateRailActive(uint256 railId) {
        require(rails[railId].from != address(0), "rail does not exist");
        require(rails[railId].isActive, "rail is inactive");
        _;
    }

    modifier noRailModificationInProgress(uint256 railId) {
        require(!rails[railId].isLocked, "Modification already in progress");
        rails[railId].isLocked = true;
        _;
        rails[railId].isLocked = false;
    }

    modifier onlyRailClient(uint256 railId) {
        require(
            rails[railId].from == msg.sender,
            "only the rail client can perform this action"
        );
        _;
    }

    modifier onlyRailOperator(uint256 railId) {
        require(
            rails[railId].operator == msg.sender,
            "only the rail operator can perform this action"
        );
        _;
    }

    modifier onlyRailParticipant(uint256 railId) {
        require(
            rails[railId].from == msg.sender ||
            rails[railId].operator == msg.sender ||
            rails[railId].to == msg.sender,
            "failed to authorize: caller is not a rail participant"
        );
        _;
    }

    modifier validateRailNotTerminated(uint256 railId) {
        require(rails[railId].terminationEpoch == 0, "rail already terminated");
        _;
    }

    function terminateOperator(address operator, address token) external {
        require(operator != address(0), "operator address cannot be zero");
        require(token != address(0), "token address cannot be zero");

        // Revoke approval for the given token
        OperatorApproval storage approval = operatorApprovals[token][
            msg.sender
            ][operator];
        approval.rateAllowance = 0;
        approval.lockupAllowance = 0;
        approval.isApproved = false;
    }

    function approveOperator(
        address token,
        address operator,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) external {
        require(token != address(0), "token address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][
            msg.sender
        ][operator];
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
        approval.isApproved = true;
    }


    function setOperatorApproval(
        address token,
        address operator,
        bool    approved,
        uint256 rateAllowance,
        uint256 lockupAllowance
    ) external {
        require(token != address(0), "token address cannot be zero");
        require(operator != address(0), "operator address cannot be zero");

        OperatorApproval storage approval = operatorApprovals[token][
            msg.sender
        ][operator];
        
        // Update approval status and allowances
        approval.isApproved = approved;
        approval.rateAllowance = rateAllowance;
        approval.lockupAllowance = lockupAllowance;
    }

    function terminateRail(
        uint256 railId
    ) external validateRailActive(railId) noRailModificationInProgress(railId) onlyRailParticipant(railId) 
        validateRailNotTerminated(railId) {

        Rail storage rail = rails[railId];
        // Set termination epoch to current block
        rail.terminationEpoch = block.number;

        // Remove the rail rate from account lockup rate but don't set rail rate to zero yet
        Account storage payer = accounts[rail.token][rail.from];
        require(
            payer.lockupRate >= rail.paymentRate,
            "lockup rate inconsistency"
        );
        payer.lockupRate -= rail.paymentRate;
    }

    function deposit(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "to address cannot be zero");
        require(amount > 0, "amount must be greater than 0");

        // Create account if it doesn't exist
        Account storage account = accounts[token][to];

        // Transfer tokens from sender to contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Update account balance
        account.funds += amount;

        // settle account lockup now that we have more funds
        settleAccountLockup(account);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        withdrawTo(token, msg.sender, amount);
    }

    function withdrawTo(
        address token,
        address to,
        uint256 amount
    ) public nonReentrant {
        require(token != address(0), "token address cannot be zero");
        require(to != address(0), "recipient address cannot be zero");

        Account storage acct = accounts[token][msg.sender];

        uint256 settleEpoch = settleAccountLockup(acct);
        require(settleEpoch == block.number, "insufficient funds");

        uint256 available = acct.funds > acct.lockupCurrent
            ? acct.funds - acct.lockupCurrent
            : 0;

        require(
            amount <= available,
            "insufficient unlocked funds for withdrawal"
        );
        acct.funds -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function createRail(
        address token,
        address from,
        address to,
        address arbiter
    ) external noRailModificationInProgress(_nextRailId) returns (uint256) {
        address operator = msg.sender;
        require(token != address(0), "token address cannot be zero");
        require(from != address(0), "from address cannot be zero");
        require(to != address(0), "to address cannot be zero");

        // Check if operator is approved - approval is required for rail creation
        OperatorApproval storage approval = operatorApprovals[token][from][
            operator
        ];
        require(approval.isApproved, "operator not approved");

        uint256 railId = _nextRailId++;

        Rail storage rail = rails[railId];
        rail.token = token;
        rail.from = from;
        rail.to = to;
        rail.operator = operator;
        rail.arbiter = arbiter;
        rail.isActive = true;
        rail.settledUpTo = block.number;
        rail.terminationEpoch = 0;

        clientOperatorRails[from][operator].push(railId);
        return railId;
    }

    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        noRailModificationInProgress(railId)
    {
        Rail storage rail = rails[railId];

        // operator can only reduce fixed lockup on a terminated rail
        // it cannot change the lockup period or increase fixed lockup
        require(
            rail.terminationEpoch == 0 || (period == rail.lockupPeriod && lockupFixed <= rail.lockupFixed),
            "failed to modify terminated rail: cannot change period or increase fixed lockup"
        );

        Account storage payer = accounts[rail.token][rail.from];
        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // settle account lockup and if account lockup is not settled upto to the current epoch; revert
        uint256 lockupSettledUpto = settleAccountLockup(payer);
        require(
            lockupSettledUpto == block.number,
            "cannot modify lockup as client does not have enough funds for current account lockup"
        );

        // Calculate the change in base lockup
        uint256 oldLockup = rail.lockupFixed +
            (rail.paymentRate * rail.lockupPeriod);
            
        // For terminated rails, only calculate lockup for the remaining period up to termination
        uint256 newLockup;
        if (rail.terminationEpoch > 0) {
            newLockup = calculateTerminatedRailLockup(
                rail,
                lockupFixed
            );
        } else {
            newLockup = lockupFixed + (rail.paymentRate * period);
        }

        // Update operator allowance tracking based on lockup changes
        validateAndUpdateLockupAllowance(
            approval,
            oldLockup,
            newLockup
        );

        // Update payer's lockup
        require(
            payer.lockupCurrent >= oldLockup,
            "payer's current lockup cannot be less than old lockup"
        );
        payer.lockupCurrent = payer.lockupCurrent - oldLockup + newLockup;

        // Update rail lockup parameters
        rail.lockupPeriod = period;
        rail.lockupFixed = lockupFixed;

        require(
            payer.lockupCurrent <= payer.funds,
            "payer's current lockup cannot be greater than their funds"
        );
    }

    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    )
        external
        validateRailActive(railId)
        onlyRailOperator(railId)
        noRailModificationInProgress(railId)
    {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        uint256 oldRate = rail.paymentRate;

        // For terminated rails, can only reduce rate, not increase it
        require(
            rail.terminationEpoch == 0 || newRate <= oldRate,
            "failed to modify rail: cannot increase rate on terminated rail"
        );

        OperatorApproval storage approval = operatorApprovals[rail.token][
            rail.from
        ][rail.operator];

        // Settle the payer's lockup to account for elapsed time
        uint256 lockupSettledUpto = settleAccountLockup(payer);
        // If we're increasing the rate, we require full account lockup setlement before we can proceed
        require(
            newRate <= oldRate || lockupSettledUpto == block.number,
            "account lockup not fully settled; cannot increase rate"
        );

        // We just settled the account lockup. If the client is still not able to guaruantee
        // enough funds to lock up for the rail upto and including the current epoch, it means that the rail is in "debt"
        // i.e. the client does not have enough funds to pay for services already taken on this rail.
        // In this case, we should not allow rate modifications at all.
        // The client should first deposit enough funds to pay for this "debt" and then the rate can be changed.
        require(
            newRate == oldRate ||
                block.number <= payer.lockupLastSettledAt + rail.lockupPeriod,
            "rail is in-debt; cannot change rate"
        );

        // --- Operator Approval Checks ---
        validateAndModifyRateChangeApproval(
            rail,
            approval,
            oldRate,
            newRate,
            oneTimePayment
        );

        // --- Settlement Prior to Rate Change ---
        // Only settle and update rate queue if the rate has changed
        if (newRate != oldRate) {
            // If there is no arbiter, settle the rail immediately.
            if (rail.arbiter == address(0)) {
                (, uint256 settledUpto, ) = settleRail(
                    railId,
                    block.number,
                    false
                );
                require(
                    settledUpto == block.number,
                    "not able to settle rail upto current epoch"
                );
            } else {
                // handle multiple rate changes by the operator in a single epoch
                // by queueuing the previous rate only once
                if (
                    rail.rateChangeQueue.isEmpty() ||
                    rail.rateChangeQueue.peekTail().untilEpoch != block.number
                ) {
                    // For arbitrated rails, we need to enqueue the old rate.
                    // This ensures that the old rate is applied up to and including the current block.
                    // The new rate will be applicable starting from the next block.
                    rail.rateChangeQueue.enqueue(oldRate, block.number);
                }
            }
        }

        // Calculate the effective lockup period (remaining period that hasn't been settled)
        uint256 effectiveLockupPeriod = rail.lockupPeriod -
            (block.number - payer.lockupLastSettledAt);

        // Verify current lockup is sufficient for the old rate component
        uint256 oldRateLockupNeeded = (oldRate * effectiveLockupPeriod) +
            oneTimePayment;

        require(
            payer.lockupCurrent >= oldRateLockupNeeded,
            "failed to modify rail payment: insufficient current lockup"
        );
        // Verify one-time payment doesn't exceed fixed lockup
        require(
            rail.lockupFixed >= oneTimePayment,
            "one time payment cannot be greater than rail lockupFixed"
        );

        // Update the rail fixed lockup and payment rate
        rail.lockupFixed = rail.lockupFixed - oneTimePayment;
        rail.paymentRate = newRate;

        // Update payer's lockup rate - only if the rail is not terminated
        if (rail.terminationEpoch == 0) {
            require(
                payer.lockupRate >= oldRate,
                "payer lockup rate cannot be less than old rate"
            );
            payer.lockupRate = payer.lockupRate - oldRate + newRate;
        }

        // Update payer's current lockup with effective lockup period calculation
        // Remove old rate lockup for the effective period, add new rate lockup for the same period
        payer.lockupCurrent =
            payer.lockupCurrent -
            (oldRate * effectiveLockupPeriod) +
            (newRate * effectiveLockupPeriod) -
            oneTimePayment;

        // --- Process the One-Time Payment ---
        processOneTimePayment(payer, payee, oneTimePayment);

        // Ensure the modified lockup doesn't exceed available funds
        require(
            payer.lockupCurrent <= payer.funds,
            "payer lockup cannot exceed funds"
        );

        // If we've reduced the rate, settle lockup again to account for changes
        // and ensure that account lockup is settled upto and including the current epoch
        if (newRate < oldRate) {
            uint256 settledUpto = settleAccountLockup(payer);
            require(settledUpto == block.number, "account lockup must be fully settled after rate decrease");
        }
    }

    function processOneTimePayment(
        Account storage payer,
        Account storage payee,
        uint256 oneTimePayment
    ) internal {
        if (oneTimePayment > 0) {
            require(
                payer.funds >= oneTimePayment,
                "insufficient funds for one-time payment"
            );
            payer.funds -= oneTimePayment;
            payee.funds += oneTimePayment;
        }
    }
   
    function calculateTerminatedRailLockup(
        Rail storage rail,
        uint256 lockupFixed
    ) internal view returns (uint256) {
        // Calculate the maximum settlement epoch for a terminated rail
        // This is the last epoch that will receive payment after termination
        uint256 maxSettlementEpoch = rail.terminationEpoch + rail.lockupPeriod;
        
        // CASE 1: RAIL FULLY SETTLED
        // If current block is at or beyond the maximum settlement epoch,
        // we only need the fixed lockup as all rate-based payments are complete
        if (block.number >= maxSettlementEpoch) {
            return lockupFixed; 
        } 
        // CASE 2: RAIL NEEDS FURTHER SETTLEMENT
       
        // Calculate how many more epochs need to be settled
        uint256 remainingEpochs = maxSettlementEpoch - block.number;
        
        // The effective period can't be more than the rail's lockup period
        uint256 effectivePeriod = min(rail.lockupPeriod, remainingEpochs);
            
        // Return fixed lockup plus the rate-based lockup for remaining epochs
        return lockupFixed + (rail.paymentRate * effectivePeriod); 
    }

    function validateAndUpdateLockupAllowance(
        OperatorApproval storage approval,
        uint256 oldLockup,
        uint256 newLockup
    ) internal {
        // Check if we're increasing or decreasing lockup
        if (newLockup >= oldLockup) {
            uint256 lockupIncrease = newLockup - oldLockup;

            // Only check allowance if we're increasing lockup
            require(
                approval.lockupUsage + lockupIncrease <= approval.lockupAllowance,
                "exceeds operator lockup allowance"
            );

            // Update usage
            approval.lockupUsage += lockupIncrease;
        } else if (newLockup < oldLockup) {
            // this should never underflow as lockupUsage should always be greater than the `oldLockup` 
            uint256 lockupDecrease = oldLockup - newLockup;
            approval.lockupUsage -= lockupDecrease;
        }
    }

    function validateAndModifyRateChangeApproval(
        Rail storage rail,
        OperatorApproval storage approval,
        uint256 oldRate,
        uint256 newRate,
        uint256 oneTimePayment
    ) internal {
        // Ensure the one-time payment does not exceed the available fixed lockup on the rail.
        require(
            oneTimePayment <= rail.lockupFixed,
            "one-time payment exceeds rail fixed lockup"
        );

        // Calculate the original total lockup amount:
        uint256 oldTotalLockup = (oldRate * rail.lockupPeriod) +
            rail.lockupFixed;
        uint256 newTotalLockup = (newRate * rail.lockupPeriod) +
            rail.lockupFixed;

        // Handle lockup allowance changes using the shared helper function
        validateAndUpdateLockupAllowance(
            approval,
            oldTotalLockup,
            newTotalLockup
        );

        // Handle rate change - allow decreases even when allowance is below usage
        if (newRate > oldRate) {
            uint256 rateIncrease = newRate - oldRate;

            // Check if increase would push usage above allowance
            require(
                approval.rateUsage + rateIncrease <= approval.rateAllowance,
                "new rate exceeds operator rate allowance"
            );

            // Update usage
            approval.rateUsage += rateIncrease;
        } else if (newRate < oldRate) {
            // For rate decreases, reduce usage
            uint256 rateDecrease = oldRate - newRate;

            // Ensure we don't underflow
            approval.rateUsage = approval.rateUsage > rateDecrease
                ? approval.rateUsage - rateDecrease
                : 0;
        }
    }

    function _handleTerminatedRailSettlement(
        Rail storage rail,
        Account storage payer
    ) internal returns (bool isFullySettled, uint256 maxSettlementEpoch, string memory noteMessage) {
        // Calculate maximum settlement epoch for terminated rail
        maxSettlementEpoch = rail.terminationEpoch + rail.lockupPeriod;

        // Check if rail is already fully settled
        if (rail.settledUpTo >= maxSettlementEpoch) {
            // If rail is still marked as active, finalize it by returning fixed lockup to client
            if (rail.isActive) {
                // Reduce the lockup by the fixed amount
                require(
                    payer.lockupCurrent >= rail.lockupFixed,
                    "lockup inconsistency during rail finalization"
                );
                payer.lockupCurrent -= rail.lockupFixed;

                // Mark rail as inactive and clear payment parameters
                rail.isActive = false;
                rail.paymentRate = 0;
                rail.lockupFixed = 0;
            }

            return (true, maxSettlementEpoch, "rail completely settled and finalized");
        }

        return (false, maxSettlementEpoch, "");
    }

    function settleRail(
        uint256 railId,
        uint256 untilEpoch,
        bool skipArbitration
    )
        public
        nonReentrant
        returns (
            uint256 totalSettledAmount,
            uint256 finalSettledEpoch,
            string memory note
        )
    {
        require(
            untilEpoch <= block.number,
            "failed to settle: cannot settle future epochs"
        );

        Rail storage rail = rails[railId];

        // Early exit if rail is inactive
        if (!rail.isActive) {
            return (0, rail.settledUpTo, "rail is inactive");
        }

        Account storage payer = accounts[rail.token][rail.from];

        // Handle terminated rails
        uint256 maxSettlementEpochForTerminated = 0;
        if (rail.terminationEpoch > 0) {
            bool isFullySettled;
            string memory terminatedNote;
            
            // Handle terminated rail settlement and get max settlement epoch
            (isFullySettled, maxSettlementEpochForTerminated, terminatedNote) = 
                _handleTerminatedRailSettlement(rail, payer);
                
            // Early return for fully settled terminated rails
            if (isFullySettled) {
                return (0, rail.settledUpTo, terminatedNote);
            }
            
            // For terminated but not fully settled rails, limit settlement window
            untilEpoch = min(untilEpoch, maxSettlementEpochForTerminated);
        }

        // Update the payer's lockup to account for elapsed time
        settleAccountLockup(payer);

        // For terminated rails, untilEpoch was already limited by maxSettlementEpochForTerminated above
        uint256 maxLockupSettlementEpoch = payer.lockupLastSettledAt + rail.lockupPeriod;
        uint256 maxSettlementEpoch = min(untilEpoch, maxLockupSettlementEpoch);

        uint256 startEpoch = rail.settledUpTo;

        // Nothing to settle (already settled or zero-duration)
        if (startEpoch >= maxSettlementEpoch) {
            return (0, startEpoch, "already settled up to requested epoch");
        }

        // For zero rate rails with empty queue, just advance the settlement epoch
        // without transferring funds
        uint256 currentRate = rail.paymentRate;
        if (currentRate == 0 && rail.rateChangeQueue.isEmpty()) {
            rail.settledUpTo = maxSettlementEpoch;
            return (0, maxSettlementEpoch, "zero rate payment rail");
        }

        // Process settlement depending on whether rate changes exist
        if (rail.rateChangeQueue.isEmpty()) {
            (uint256 amount, string memory segmentNote) = _settleSegment(
                railId,
                startEpoch,
                maxSettlementEpoch,
                currentRate,
                skipArbitration
            );

            require(rail.settledUpTo > startEpoch, "No progress in settlement");
            return (amount, rail.settledUpTo, segmentNote);
        } else {
            return
                _settleWithRateChanges(
                    railId,
                    currentRate,
                    startEpoch,
                    maxSettlementEpoch,
                    skipArbitration
                );
        }
    }

    function _settleWithRateChanges(
        uint256 railId,
        uint256 currentRate,
        uint256 startEpoch,
        uint256 targetEpoch,
        bool skipArbitration
    )
        internal
        returns (uint256 totalSettled, uint256 finalEpoch, string memory note)
    {
        Rail storage rail = rails[railId];
        RateChangeQueue.Queue storage rateQueue = rail.rateChangeQueue;

        totalSettled = 0;
        uint256 processedEpoch = startEpoch;
        note = "";

        // Process each segment until we reach the target epoch or hit an early exit condition
        while (processedEpoch < targetEpoch) {
            // Default boundary is the target we want to reach
            uint256 segmentEndBoundary = targetEpoch;
            uint256 segmentRate;

            // If we have rate changes in the queue, use the rate from the next change
            if (!rateQueue.isEmpty()) {
                RateChangeQueue.RateChange memory nextRateChange = rateQueue
                    .peek();

                // Validate rate change queue consistency
                require(
                    nextRateChange.untilEpoch >= processedEpoch,
                    "rate queue is in an invalid state"
                );

                // Boundary is the minimum of our target or the next rate change epoch
                segmentEndBoundary = min(
                    targetEpoch,
                    nextRateChange.untilEpoch
                );
                segmentRate = nextRateChange.rate;
            } else {
                // If queue is empty, use the current rail rate
                segmentRate = currentRate;

                // if current rate is zero, there's nothing left to do and we've finished settlement
                if (segmentRate == 0) {
                    rail.settledUpTo = targetEpoch;
                    return (
                        totalSettled,
                        rail.settledUpTo,
                        "Zero rate payment rail"
                    );
                }
            }

            // Settle the current segment with potentially arbitrated outcomes
            (
                uint256 segmentAmount,
                string memory arbitrationNote
            ) = _settleSegment(
                    railId,
                    processedEpoch,
                    segmentEndBoundary,
                    segmentRate,
                    skipArbitration
                );

            // If arbiter returned no progress, exit early without updating state
            if (rail.settledUpTo <= processedEpoch) {
                return (totalSettled, rail.settledUpTo, arbitrationNote);
            }

            // Add the settled amount to our running total
            totalSettled += segmentAmount;

            // If arbiter partially settled the segment, exit early
            if (rail.settledUpTo < segmentEndBoundary) {
                return (totalSettled, rail.settledUpTo, arbitrationNote);
            }

            // Successfully settled full segment, update tracking values
            processedEpoch = rail.settledUpTo;
            note = arbitrationNote;

            // Remove the processed rate change from the queue
            if (!rateQueue.isEmpty()) {
                rateQueue.dequeue();
            }
        }

        // We've successfully settled up to the target epoch
        return (totalSettled, rail.settledUpTo, note);
    }

    function _settleSegment(
        uint256 railId,
        uint256 epochStart,
        uint256 epochEnd,
        uint256 rate,
        bool skipArbitration
    ) internal returns (uint256 settledAmount, string memory note) {
        Rail storage rail = rails[railId];
        Account storage payer = accounts[rail.token][rail.from];
        Account storage payee = accounts[rail.token][rail.to];

        // Calculate the default settlement values (without arbitration)
        uint256 duration = epochEnd - epochStart;
        settledAmount = rate * duration;
        uint256 settledUntilEpoch = epochEnd;
        note = "";

        // If this rail has an arbiter and we're not skipping arbitration, let it decide on the final settlement amount
        if (rail.arbiter != address(0) && !skipArbitration) {
            IArbiter arbiter = IArbiter(rail.arbiter);
            IArbiter.ArbitrationResult memory result = arbiter.arbitratePayment(
                railId,
                settledAmount,
                epochStart,
                epochEnd
            );

            // Ensure arbiter doesn't settle beyond our segment's end boundary
            require(
                result.settleUpto <= epochEnd,
                "arbiter settled beyond segment end"
            );
            require(
                result.settleUpto >= epochStart,
                "arbiter settled before segment start"
            );

            settledUntilEpoch = result.settleUpto;
            settledAmount = result.modifiedAmount;
            note = result.note;

            // Ensure arbiter doesn't allow more payment than the maximum possible
            // for the epochs they're confirming
            uint256 maxAllowedAmount = rate * (settledUntilEpoch - epochStart);
            require(
                result.modifiedAmount <= maxAllowedAmount,
                "arbiter modified amount exceeds maximum for settled duration"
            );
        }

        // Verify payer has sufficient funds for the settlement
        require(
            payer.funds >= settledAmount,
            "failed to settle: insufficient funds to cover settlement"
        );

        // Verify payer has sufficient lockup for the settlement
        require(
            payer.lockupCurrent >= settledAmount,
            "failed to settle: insufficient lockup to cover settlement"
        );

        // Transfer funds from payer to payee
        payer.funds -= settledAmount;
        payee.funds += settledAmount;

        // Reduce the lockup by the settled amount
        payer.lockupCurrent -= settledAmount;

        // Update the rail's settled epoch
        rail.settledUpTo = settledUntilEpoch;

        // Invariant check: lockup should never exceed funds
        require(
            payer.lockupCurrent <= payer.funds,
            "failed to settle: insufficient funds to cover lockup after settlement"
        );

        return (settledAmount, note);
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    // attempts to settle account lockup up to and including the current epoch
    // returns the actual epoch upto and including which the lockup was settled
    function settleAccountLockup(
        Account storage account
    ) internal returns (uint256 settledUpto) {
        uint256 currentEpoch = block.number;
        uint256 elapsedTime = currentEpoch - account.lockupLastSettledAt;

        if (elapsedTime <= 0) {
            return account.lockupLastSettledAt;
        }

        if (account.lockupRate == 0) {
            account.lockupLastSettledAt = currentEpoch;
            return currentEpoch;
        }

        uint256 additionalLockup = account.lockupRate * elapsedTime;

        if (account.funds >= account.lockupCurrent + additionalLockup) {
            // If sufficient, apply full lockup
            account.lockupCurrent += additionalLockup;
            account.lockupLastSettledAt = currentEpoch;
            return currentEpoch;
        } else {
            // If insufficient, calculate the fractional epoch where funds became insufficient
            uint256 availableFunds = account.funds > account.lockupCurrent
                ? account.funds - account.lockupCurrent
                : 0;

            if (availableFunds == 0) {
                return account.lockupLastSettledAt;
            }

            // Round down to the nearest whole epoch
            uint256 fractionalEpochs = availableFunds / account.lockupRate;
            settledUpto = account.lockupLastSettledAt + fractionalEpochs;
            // Apply lockup up to this point
            account.lockupCurrent += account.lockupRate * fractionalEpochs;
            account.lockupLastSettledAt = settledUpto;
            return settledUpto;
        }
    }

    // returns how many epochs worth of payment can be made by this client for the given
    // rail excluding the current epoch
    function getFuturePaymentEpochsForRail(
        uint256 railId
    ) external view returns (RailPaymentCapability memory) {
        Rail storage rail = rails[railId];

        if (!rail.isActive) {
            return RailPaymentCapability(true, true, 0);
        }

        if (rail.paymentRate == 0) {
            return RailPaymentCapability(false, true, 0);
        }

        // Check if rail is terminated and already settled
        if (rail.terminationEpoch > 0) {
            uint256 maxSettlementEpochForTerminated = rail.terminationEpoch +
                rail.lockupPeriod;
            if (block.number >= maxSettlementEpochForTerminated) {
                return RailPaymentCapability(true, true, 0);
            } else {
                // Calculate how many epochs in the future we can guarantee payment for this terminated but unsettled rail
                uint256 remainingEpochs = maxSettlementEpochForTerminated -
                    block.number;
                return RailPaymentCapability(true, false, remainingEpochs);
            }
        }

        // Determine the maximum future time the client can pay based on their current funds
        Account memory account = accounts[rail.token][rail.from];
        require(
            account.lockupRate != 0,
            "account lockup can not be zero if rail rate is non-zero"
        );

        // First ensure we get an accurate view of current lockup by computing elapsed time
        uint256 elapsedTime = block.number - account.lockupLastSettledAt;
        uint256 currentLockupRequired = account.lockupCurrent +
            (account.lockupRate * elapsedTime);

        if (account.funds >= currentLockupRequired) {
            uint256 remainingFunds = account.funds - currentLockupRequired;

            uint256 additionalEpochs = remainingFunds / account.lockupRate;

            return
                RailPaymentCapability(
                    false,
                    false,
                    rail.lockupPeriod + additionalEpochs
                );
        } else {
            // If insufficient, calculate the fractional epoch where funds became insufficient
            uint256 availableFunds = account.funds > account.lockupCurrent
                ? account.funds - account.lockupCurrent
                : 0;

            if (availableFunds == 0) {
                return RailPaymentCapability(false, false, 0);
            }

            // Round down to the nearest whole epoch
            uint256 fractionalEpochs = availableFunds / account.lockupRate;
            uint256 settledUpto = account.lockupLastSettledAt +
                fractionalEpochs;

            return
                RailPaymentCapability(
                    false,
                    false,
                    rail.lockupPeriod + settledUpto
                );
        }
    }
}
