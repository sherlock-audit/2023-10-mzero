// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { IBatchGovernor } from "./IBatchGovernor.sol";

/**
 * @title  Extension for BatchGovernor with a threshold ratio used to determine quorum and yes-threshold requirements.
 * @author M^0 Labs
 */
interface IThresholdGovernor is IBatchGovernor {
    /* ============ Events ============ */

    /**
     * @notice Emitted when the threshold ratio is set.
     * @param  thresholdRatio The new threshold ratio.
     */
    event ThresholdRatioSet(uint16 thresholdRatio);

    /* ============ Custom Errors ============ */

    /**
     * @notice Revert message when trying to set the threshold ratio above 100% or below 2.71%.
     * @param  thresholdRatio    The threshold ratio being set.
     * @param  minThresholdRatio The minimum allowed threshold ratio.
     * @param  maxThresholdRatio The maximum allowed threshold ratio.
     */
    error InvalidThresholdRatio(uint256 thresholdRatio, uint256 minThresholdRatio, uint256 maxThresholdRatio);

    /* ============ View/Pure Functions ============ */

    /**
     * @notice Returns all data of a proposal with identifier `proposalId`.
     * @param  proposalId     The unique identifier for the proposal.
     * @return voteStart      The first clock value when voting on the proposal is allowed.
     * @return voteEnd        The last clock value when voting on the proposal is allowed.
     * @return state          The state of the proposal.
     * @return noVotes        The amount of votes cast against the proposal.
     * @return yesVotes       The amount of votes cast for the proposal.
     * @return proposer       The address of the account that created the proposal.
     * @return thresholdRatio The threshold ratio to be applied to determine the threshold/quorum for the proposal.
     */
    function getProposal(
        uint256 proposalId
    )
        external
        view
        returns (
            uint48 voteStart,
            uint48 voteEnd,
            ProposalState state,
            uint256 noVotes,
            uint256 yesVotes,
            address proposer,
            uint16 thresholdRatio
        );

    /// @notice Returns the threshold ratio to be applied to determine the threshold/quorum for a proposal.
    function thresholdRatio() external view returns (uint16);
}
