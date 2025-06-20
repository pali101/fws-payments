// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPayments
/// @notice Interface for the Payments contract, defining all external functions and relevant structs.
interface IPayments {
    // -------- Structs --------

    /// @notice Account data for each user and token.
    struct Account {
        uint256 funds;
        uint256 lockupCurrent;
        uint256 lockupRate;
        uint256 lockupLastSettledAt;
    }

    /// @notice Struct returned by getRail, representing a rail's public state (excluding internal-only fields).
    struct RailView {
        address token;
        address from;
        address to;
        address operator;
        address arbiter;
        uint256 paymentRate;
        uint256 lockupPeriod;
        uint256 lockupFixed;
        uint256 settledUpTo;
        uint256 endEpoch;
        uint256 commissionRateBps;
    }

    /// @notice Approval and usage stats for operators managing rails on behalf of clients.
    struct OperatorApproval {
        bool isApproved;
        uint256 rateAllowance;
        uint256 lockupAllowance;
        uint256 rateUsage;
        uint256 lockupUsage;
        uint256 maxLockupPeriod;
    }

    /// @notice Define a struct for rails by payee information
    struct RailInfo {
        uint256 railId; 
        bool isTerminated; 
        uint256 endEpoch;
    }

    /// @notice Settlement state for a rail.
    struct SettlementState {
        uint256 totalSettledAmount;
        uint256 totalNetPayeeAmount;
        uint256 totalPaymentFee;
        uint256 totalOperatorCommission;
        uint256 processedEpoch;
        string note;
    }

    // -------- Events --------

    /// @notice Emitted when tokens are deposited using permit (EIP-2612).
    event DepositWithPermit(
        address indexed token,
        address indexed from,
        address indexed to,
        uint256 amount
    );

    // -------- Functions --------
    // Marking public functions as external as solidity doesn't allow external functions to be marked as public in interfaces.

    /// @notice Initializes the Payments contract (for upgradeable proxies).
    function initialize() external;

    /// @notice Gets the current state of the target rail or reverts if the rail isn't active.
    /// @param railId the ID of the rail.
    function getRail(uint256 railId) external view returns (RailView memory);

    /// @notice Updates the approval status and allowances for an operator on behalf of the message sender.
    /// @param token The ERC20 token address for which the approval is being set.
    /// @param operator The address of the operator whose approval is being modified.
    /// @param approved Whether the operator is approved (true) or not (false) to create new rails>
    /// @param rateAllowance The maximum payment rate the operator can set across all rails created by the operator on behalf of the message sender. If this is less than the current payment rate, the operator will only be able to reduce rates until they fall below the target.
    /// @param lockupAllowance The maximum amount of funds the operator can lock up on behalf of the message sender towards future payments. If this exceeds the current total amount of funds locked towards future payments, the operator will only be able to reduce future lockup.
    /// @param maxLockupPeriod The maximum number of epochs (blocks) the operator can lock funds for. If this is less than the current lockup period for a rail, the operator will only be able to reduce the lockup period.
    function setOperatorApproval(
        address token,
        address operator,
        bool approved,
        uint256 rateAllowance,
        uint256 lockupAllowance,
        uint256 maxLockupPeriod
    ) external;

    /// @notice Terminates a payment rail, preventing further payments after the rail's lockup period. After calling this method, the lockup period cannot be changed, and the rail's rate and fixed lockup may only be reduced.
    /// @param railId The ID of the rail to terminate.
    function terminateRail(uint256 railId) external;

    /// @notice Deposits tokens from the message sender's account into `to`'s account.
    /// @param token The ERC20 token address to deposit.
    /// @param to The address whose account will be credited.
    /// @param amount The amount of tokens to deposit.
    function deposit(
        address token,
        address to,
        uint256 amount
    ) external payable;

    /**
     * @notice Deposits tokens using permit (EIP-2612) approval in a single transaction.
     * @param token The ERC20 token address to deposit.
     * @param to The address whose account will be credited.
     * @param amount The amount of tokens to deposit.
     * @param deadline Permit deadline (timestamp).
     * @param v,r,s Permit signature.
     */
    function depositWithPermit(
        address token,
        address to,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Withdraws tokens from the caller's account to the caller's account, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param amount The amount of tokens to withdraw.
    function withdraw(address token, uint256 amount) external;

    /// @notice Withdraws tokens (`token`) from the caller's account to `to`, up to the amount of currently available tokens (the tokens not currently locked in rails).
    /// @param token The ERC20 token address to withdraw.
    /// @param to The address to receive the withdrawn tokens.
    /// @param amount The amount of tokens to withdraw.
    function withdrawTo(address token, address to, uint256 amount) external;

    /// @notice Create a new rail from `from` to `to`, operated by the caller.
    /// @param token The ERC20 token address for payments on this rail.
    /// @param from The client address (payer) for this rail.
    /// @param to The recipient address for payments on this rail.
    /// @param arbiter Optional address of an arbiter contract (can be address(0) for no arbitration).
    /// @param commissionRateBps Optional operator commission in basis points (0-10000).
    /// @return The ID of the newly created rail.
    function createRail(
        address token,
        address from,
        address to,
        address arbiter,
        uint256 commissionRateBps
    ) external returns (uint256);

    /// @notice Modifies the fixed lockup and lockup period of a rail.
    /// - If the rail has already been terminated, the lockup period may not be altered and the fixed lockup may only be reduced.
    /// - If the rail is active, the lockup may only be modified if the payer's account is fully funded and will remain fully funded after the operation.
    /// @param railId The ID of the rail to modify.
    /// @param period The new lockup period (in epochs/blocks).
    /// @param lockupFixed The new fixed lockup amount.
    function modifyRailLockup(
        uint256 railId,
        uint256 period,
        uint256 lockupFixed
    ) external;

    /// @notice Modifies the payment rate and optionally makes a one-time payment.
    /// - If the rail has already been terminated, one-time payments can be made and the rate may always be decreased (but never increased) regardless of the status of the payer's account.
    /// - If the payer's account isn't fully funded and the rail is active (not terminated), the rail's payment rate may not be changed at all (increased or decreased).
    /// - Regardless of the payer's account status, one-time payments will always go through provided that the rail has sufficient fixed lockup to cover the payment.
    /// @param railId The ID of the rail to modify.
    /// @param newRate The new payment rate (per epoch). This new rate applies starting the next epoch after the current one.
    /// @param oneTimePayment Optional one-time payment amount to transfer immediately, taken out of the rail's fixed lockup.
    function modifyRailPayment(
        uint256 railId,
        uint256 newRate,
        uint256 oneTimePayment
    ) external;

    /// @notice Settles payments for a terminated rail without arbitration. This may only be called by the payee and after the terminated rail's max settlement epoch has passed. It's an escape-hatch to unblock payments in an otherwise stuck rail (e.g., due to a buggy arbiter contract) and it always pays in full.
    /// @param railId The ID of the rail to settle.
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return totalNetPayeeAmount The net amount credited to the payee after fees.
    /// @return totalPaymentFee The fee retained by the payment contract.
    /// @return totalOperatorCommission The commission credited to the operator.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement.
    function settleTerminatedRailWithoutArbitration(
        uint256 railId
    )
        external
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalPaymentFee,
            uint256 totalOperatorCommission,
            uint256 finalSettledEpoch,
            string memory note
        );

    /// @notice Settles payments for a rail up to the specified epoch. Settlement may fail to reach the target epoch if either the client lacks the funds to pay up to the current epoch or the arbiter refuses to settle the entire requested range.
    /// @param railId The ID of the rail to settle.
    /// @param untilEpoch The epoch up to which to settle (must not exceed current block number).
    /// @return totalSettledAmount The total amount settled and transferred.
    /// @return totalNetPayeeAmount The net amount credited to the payee after fees.
    /// @return totalPaymentFee The fee retained by the payment contract.
    /// @return totalOperatorCommission The commission credited to the operator.
    /// @return finalSettledEpoch The epoch up to which settlement was actually completed.
    /// @return note Additional information about the settlement (especially from arbitration).
    function settleRail(
        uint256 railId,
        uint256 untilEpoch
    )
        external
        returns (
            uint256 totalSettledAmount,
            uint256 totalNetPayeeAmount,
            uint256 totalPaymentFee,
            uint256 totalOperatorCommission,
            uint256 finalSettledEpoch,
            string memory note
        );

    /// @notice Allows the contract owner to withdraw accumulated payment fees.
    /// @param token The ERC20 token address of the fees to withdraw.
    /// @param to The address to send the withdrawn fees to.
    /// @param amount The amount of fees to withdraw.
    function withdrawFees(
        address token,
        address to,
        uint256 amount
    ) external;

    /// @notice Returns information about all accumulated fees
    /// @return tokens Array of token addresses that have accumulated fees
    /// @return amounts Array of fee amounts corresponding to each token
    /// @return count Total number of tokens with accumulated fees
    function getAllAccumulatedFees()
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory amounts,
            uint256 count
        );

    /**
     * @notice Gets all rails where the given address is the payer for a specific token.
     * @param payer The address of the payer to get rails for.
     * @param token The token address to filter rails by.
     * @return Array of RailInfo structs containing rail IDs and termination status.
     */
    function getRailsForPayerAndToken(
        address payer,
        address token
    ) external view returns (RailInfo[] memory);

    /**
     * @notice Gets all rails where the given address is the payee for a specific token.
     * @param payee The address of the payee to get rails for.
     * @param token The token address to filter rails by.
     * @return Array of RailInfo structs containing rail IDs and termination status.
     */
    function getRailsForPayeeAndToken(
        address payee,
        address token
    ) external view returns (RailInfo[] memory);
}
