// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import { SignatureChecker } from "../lib/common/src/libs/SignatureChecker.sol";

import { ERC712Extended } from "../lib/common/src/ERC712Extended.sol";
import { UIntMath } from "../lib/common/src/libs/UIntMath.sol";

import { TTGRegistrarReader } from "./libs/TTGRegistrarReader.sol";

import { IContinuousIndexing } from "./interfaces/IContinuousIndexing.sol";
import { IMToken } from "./interfaces/IMToken.sol";
import { IMinterGateway } from "./interfaces/IMinterGateway.sol";
import { IRateModel } from "./interfaces/IRateModel.sol";

import { ContinuousIndexing } from "./abstract/ContinuousIndexing.sol";
import { ContinuousIndexingMath } from "./libs/ContinuousIndexingMath.sol";

/*

███╗   ███╗██╗███╗   ██╗████████╗███████╗██████╗      ██████╗  █████╗ ████████╗███████╗██╗    ██╗ █████╗ ██╗   ██╗
████╗ ████║██║████╗  ██║╚══██╔══╝██╔════╝██╔══██╗    ██╔════╝ ██╔══██╗╚══██╔══╝██╔════╝██║    ██║██╔══██╗╚██╗ ██╔╝
██╔████╔██║██║██╔██╗ ██║   ██║   █████╗  ██████╔╝    ██║  ███╗███████║   ██║   █████╗  ██║ █╗ ██║███████║ ╚████╔╝ 
██║╚██╔╝██║██║██║╚██╗██║   ██║   ██╔══╝  ██╔══██╗    ██║   ██║██╔══██║   ██║   ██╔══╝  ██║███╗██║██╔══██║  ╚██╔╝  
██║ ╚═╝ ██║██║██║ ╚████║   ██║   ███████╗██║  ██║    ╚██████╔╝██║  ██║   ██║   ███████╗╚███╔███╔╝██║  ██║   ██║   
╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚═╝  ╚═╝     ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝   
                                                                                                                  

*/

/**
 * @title  MinterGateway
 * @author M^0 Labs
 * @notice Minting Gateway of M Token for all approved by TTG and activated minters.
 */
contract MinterGateway is IMinterGateway, ContinuousIndexing, ERC712Extended {
    /* ============ Structs ============ */

    /**
     * @notice Mint proposal struct.
     * @param  id          The unique ID of the mint proposal.
     * @param  createdAt   The timestamp at which the mint proposal was created.
     * @param  destination The address to mint M to.
     * @param  amount      The amount of M to mint.
     */
    struct MintProposal {
        // 1st slot
        uint48 id;
        uint40 createdAt;
        address destination;
        // 2nd slot
        uint240 amount;
    }

    /**
     * @notice Minter state struct.
     * @param  isActive                Whether the minter is active or not.
     * @param  isDeactivated           Whether the minter is deactivated or not.
     * @param  collateral              The amount of collateral the minter has.
     * @param  totalPendingRetrievals  The total amount of pending retrievals.
     * @param  updateTimestamp         The timestamp at which the minter last updated their collateral.
     * @param  penalizedUntilTimestamp The timestamp until which the minter is penalized.
     * @param  frozenUntilTimestamp    The timestamp until which the minter is frozen.
     */
    struct MinterState {
        // 1st slot
        bool isActive;
        bool isDeactivated;
        uint240 collateral;
        // 2nd slot
        uint240 totalPendingRetrievals;
        // 3rd slot
        uint40 updateTimestamp;
        uint40 penalizedUntilTimestamp;
        uint40 frozenUntilTimestamp;
    }

    /* ============ Variables ============ */

    /// @inheritdoc IMinterGateway
    uint16 public constant ONE = 10_000;

    /// @inheritdoc IMinterGateway
    uint32 public constant MAX_MINT_RATIO = 65_000;

    // solhint-disable-next-line max-line-length
    /// @dev keccak256("UpdateCollateral(address minter,uint256 collateral,uint256[] retrievalIds,bytes32 metadataHash,uint256 timestamp)")
    /// @inheritdoc IMinterGateway
    bytes32 public constant UPDATE_COLLATERAL_TYPEHASH =
        0x22b57ca54bd15c6234b29e87aa1d76a0841b6e65e63d7acacef989de0bc3ff9e;

    /// @inheritdoc IMinterGateway
    address public immutable ttgRegistrar;

    /// @inheritdoc IMinterGateway
    address public immutable ttgVault;

    /// @inheritdoc IMinterGateway
    address public immutable mToken;

    /// @inheritdoc IMinterGateway
    uint240 public totalInactiveOwedM;

    /// @inheritdoc IMinterGateway
    uint112 public principalOfTotalActiveOwedM;

    /// @dev Nonce used to generate unique mint proposal IDs.
    uint48 internal _mintNonce;

    /// @dev Nonce used to generate unique retrieval proposal IDs.
    uint48 internal _retrievalNonce;

    /// @dev The state of each minter, their collaterals, relevant timestamps, and total pending retrievals.
    mapping(address minter => MinterState state) internal _minterStates;

    /// @dev The mint proposals of minter (mint ID, creation timestamp, destination, amount).
    mapping(address minter => MintProposal proposal) internal _mintProposals;

    /// @dev The owed M of active and inactive minters (principal of active, inactive).
    mapping(address minter => uint240 rawOwedM) internal _rawOwedM;

    /// @dev The pending collateral retrievals of minter (retrieval ID, amount).
    mapping(address minter => mapping(uint48 retrievalId => uint240 amount)) internal _pendingCollateralRetrievals;

    /* ============ Modifiers ============ */

    /**
     * @notice Only allow active minter to call function.
     * @param  minter_ The address of the minter to check.
     */
    modifier onlyActiveMinter(address minter_) {
        _revertIfInactiveMinter(minter_);

        _;
    }

    /// @notice Only allow approved validator in TTG to call function.
    modifier onlyApprovedValidator() {
        _revertIfNotApprovedValidator(msg.sender);

        _;
    }

    /// @notice Only allow unfrozen minter to call function.
    modifier onlyUnfrozenMinter() {
        _revertIfFrozenMinter(msg.sender);

        _;
    }

    /* ============ Constructor ============ */

    /**
     * @notice Constructor.
     * @param  ttgRegistrar_ The address of the TTG Registrar contract.
     * @param  mToken_        The address of the M Token.
     */
    constructor(address ttgRegistrar_, address mToken_) ContinuousIndexing() ERC712Extended("MinterGateway") {
        if ((ttgRegistrar = ttgRegistrar_) == address(0)) revert ZeroTTGRegistrar();
        if ((ttgVault = TTGRegistrarReader.getVault(ttgRegistrar_)) == address(0)) revert ZeroTTGVault();
        if ((mToken = mToken_) == address(0)) revert ZeroMToken();
    }

    /* ============ Interactive Functions ============ */

    /// @inheritdoc IMinterGateway
    function updateCollateral(
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        address[] calldata validators_,
        uint256[] calldata timestamps_,
        bytes[] calldata signatures_
    ) external onlyActiveMinter(msg.sender) returns (uint40 minTimestamp_) {
        if (validators_.length != signatures_.length || signatures_.length != timestamps_.length) {
            revert SignatureArrayLengthsMismatch();
        }

        // Verify that enough valid signatures are provided, and get the minimum timestamp across all valid signatures.
        minTimestamp_ = _verifyValidatorSignatures(
            msg.sender,
            collateral_,
            retrievalIds_,
            metadataHash_,
            validators_,
            timestamps_,
            signatures_
        );

        uint240 safeCollateral_ = UIntMath.safe240(collateral_);
        uint240 totalResolvedCollateralRetrieval_ = _resolvePendingRetrievals(msg.sender, retrievalIds_);

        emit CollateralUpdated(
            msg.sender,
            safeCollateral_,
            totalResolvedCollateralRetrieval_,
            metadataHash_,
            minTimestamp_
        );

        _imposePenaltyIfMissedCollateralUpdates(msg.sender);

        _updateCollateral(msg.sender, safeCollateral_, minTimestamp_);

        _imposePenaltyIfUndercollateralized(msg.sender);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function proposeRetrieval(uint256 collateral_) external onlyActiveMinter(msg.sender) returns (uint48 retrievalId_) {
        if (collateral_ == 0) revert ZeroRetrievalAmount();

        unchecked {
            retrievalId_ = ++_retrievalNonce;
        }

        MinterState storage minterState_ = _minterStates[msg.sender];
        uint240 currentCollateral_ = minterState_.collateral;
        uint240 safeCollateral_ = UIntMath.safe240(collateral_);
        uint240 updatedTotalPendingRetrievals_ = minterState_.totalPendingRetrievals + safeCollateral_;

        // NOTE: Revert if collateral is less than sum of all pending retrievals even if there is no owed M by minter.
        if (currentCollateral_ < updatedTotalPendingRetrievals_) {
            revert RetrievalsExceedCollateral(updatedTotalPendingRetrievals_, currentCollateral_);
        }

        minterState_.totalPendingRetrievals = updatedTotalPendingRetrievals_;
        _pendingCollateralRetrievals[msg.sender][retrievalId_] = safeCollateral_;

        _revertIfUndercollateralized(msg.sender, 0);

        emit RetrievalCreated(retrievalId_, msg.sender, safeCollateral_);
    }

    /// @inheritdoc IMinterGateway
    function proposeMint(
        uint256 amount_,
        address destination_
    ) external onlyActiveMinter(msg.sender) onlyUnfrozenMinter returns (uint48 mintId_) {
        if (amount_ == 0) revert ZeroMintAmount();
        if (destination_ == address(0)) revert ZeroMintDestination();

        uint240 safeAmount_ = UIntMath.safe240(amount_);

        _revertIfUndercollateralized(msg.sender, safeAmount_); // Ensure minter remains sufficiently collateralized.

        unchecked {
            mintId_ = ++_mintNonce;
        }

        _mintProposals[msg.sender] = MintProposal(mintId_, uint40(block.timestamp), destination_, safeAmount_);

        emit MintProposed(mintId_, msg.sender, safeAmount_, destination_);
    }

    /// @inheritdoc IMinterGateway
    function mintM(
        uint256 mintId_
    ) external onlyActiveMinter(msg.sender) onlyUnfrozenMinter returns (uint112 principalAmount_, uint240 amount_) {
        MintProposal storage mintProposal_ = _mintProposals[msg.sender];

        uint48 id_;
        uint40 createdAt_;
        address destination_;
        (id_, createdAt_, destination_, amount_) = (
            mintProposal_.id,
            mintProposal_.createdAt,
            mintProposal_.destination,
            mintProposal_.amount
        );

        if (id_ != mintId_) revert InvalidMintProposal();

        unchecked {
            // Check that mint proposal is executable.
            uint40 activeAt_ = createdAt_ + mintDelay();
            if (block.timestamp < activeAt_) revert PendingMintProposal(activeAt_);

            uint40 expiresAt_ = activeAt_ + mintTTL();
            if (block.timestamp > expiresAt_) revert ExpiredMintProposal(expiresAt_);
        }

        _revertIfUndercollateralized(msg.sender, amount_); // Ensure minter remains sufficiently collateralized.

        delete _mintProposals[msg.sender]; // Delete mint request.

        // Adjust principal of active owed M for minter.
        // NOTE: When minting a present amount, round the principal up in favor of the protocol.
        principalAmount_ = _getPrincipalAmountRoundedUp(amount_);
        uint112 principalOfTotalActiveOwedM_ = principalOfTotalActiveOwedM;

        emit MintExecuted(id_, principalAmount_, amount_);

        unchecked {
            uint256 newPrincipalOfTotalActiveOwedM_ = uint256(principalOfTotalActiveOwedM_) + principalAmount_;

            // As an edge case precaution, prevent a mint that, if all owed M (active and inactive) was converted to
            // a principal active amount, would overflow the `uint112 principalOfTotalActiveOwedM`.
            if (
                // NOTE: Round the principal up for worst case.
                newPrincipalOfTotalActiveOwedM_ + _getPrincipalAmountRoundedUp(totalInactiveOwedM) >= type(uint112).max
            ) {
                revert OverflowsPrincipalOfTotalOwedM();
            }

            principalOfTotalActiveOwedM = uint112(newPrincipalOfTotalActiveOwedM_);
            _rawOwedM[msg.sender] += principalAmount_; // Treat rawOwedM as principal since minter is active.
        }

        IMToken(mToken).mint(destination_, amount_);

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the mint
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function burnM(address minter_, uint256 maxAmount_) external returns (uint112 principalAmount_, uint240 amount_) {
        (principalAmount_, amount_) = burnM(
            minter_,
            _getPrincipalAmountRoundedDown(UIntMath.safe240(maxAmount_)),
            maxAmount_
        );
    }

    /// @inheritdoc IMinterGateway
    function burnM(
        address minter_,
        uint256 maxPrincipalAmount_,
        uint256 maxAmount_
    ) public returns (uint112 principalAmount_, uint240 amount_) {
        if (maxPrincipalAmount_ == 0 || maxAmount_ == 0) revert ZeroBurnAmount();

        bool isActive_ = _minterStates[minter_].isActive;

        if (isActive_) {
            // NOTE: Penalize only for missed collateral updates, not for undercollateralization.
            // Undercollateralization within one update interval is forgiven.
            _imposePenaltyIfMissedCollateralUpdates(minter_);

            (principalAmount_, amount_) = _repayForActiveMinter(
                minter_,
                UIntMath.safe112(maxPrincipalAmount_),
                UIntMath.safe240(maxAmount_)
            );

            emit BurnExecuted(minter_, principalAmount_, amount_, msg.sender);
        } else {
            amount_ = _repayForInactiveMinter(minter_, UIntMath.safe240(maxAmount_));

            emit BurnExecuted(minter_, amount_, msg.sender);
        }

        IMToken(mToken).burn(msg.sender, amount_); // Burn actual M tokens

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the burn
        //       can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IMinterGateway
    function cancelMint(address minter_, uint256 mintId_) external onlyApprovedValidator {
        uint48 id_ = _mintProposals[minter_].id;

        if (id_ != mintId_ || id_ == 0) revert InvalidMintProposal();

        delete _mintProposals[minter_];

        emit MintCanceled(id_, msg.sender);
    }

    /// @inheritdoc IMinterGateway
    function freezeMinter(address minter_) external onlyApprovedValidator returns (uint40 frozenUntil_) {
        unchecked {
            _minterStates[minter_].frozenUntilTimestamp = frozenUntil_ = uint40(block.timestamp) + minterFreezeTime();
        }

        emit MinterFrozen(minter_, frozenUntil_);
    }

    /// @inheritdoc IMinterGateway
    function activateMinter(address minter_) external {
        if (!isMinterApproved(minter_)) revert NotApprovedMinter();
        if (_minterStates[minter_].isDeactivated) revert DeactivatedMinter();

        _minterStates[minter_].isActive = true;

        emit MinterActivated(minter_, msg.sender);
    }

    /// @inheritdoc IMinterGateway
    function deactivateMinter(address minter_) external onlyActiveMinter(minter_) returns (uint240 inactiveOwedM_) {
        if (isMinterApproved(minter_)) revert StillApprovedMinter();

        uint112 principalOfActiveOwedM_ = principalOfActiveOwedMOf(minter_);

        unchecked {
            // As an edge case precaution, if the resulting principal plus penalties is greater than the max uint112,
            // then max out the principal.
            uint112 newPrincipalOfOwedM_ = UIntMath.bound112(
                uint256(principalOfActiveOwedM_) + _getPenaltyPrincipalForMissedCollateralUpdates(minter_)
            );

            inactiveOwedM_ = _getPresentAmount(newPrincipalOfOwedM_);

            // Treat rawOwedM as principal since minter is active.
            principalOfTotalActiveOwedM -= principalOfActiveOwedM_;
            totalInactiveOwedM += inactiveOwedM_;
        }

        emit MinterDeactivated(minter_, inactiveOwedM_, msg.sender);

        // Reset reasonable aspects of minter's state.
        delete _minterStates[minter_];
        delete _mintProposals[minter_];

        // Deactivate minter.
        _minterStates[minter_].isDeactivated = true;

        _rawOwedM[minter_] = inactiveOwedM_; // Treat rawOwedM as inactive owed M since minter is now inactive.

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the
        //       deactivation can result in a new rate, we should update the index here to lock in that rate.
        updateIndex();
    }

    /// @inheritdoc IContinuousIndexing
    function updateIndex() public override(IContinuousIndexing, ContinuousIndexing) returns (uint128 index_) {
        // NOTE: Since the currentIndex of the Minter Gateway and mToken are constant through this context's execution
        //       (the block.timestamp is not changing) we can compute excessOwedM without updating the mToken index.
        uint240 excessOwedM_ = excessOwedM();

        if (excessOwedM_ > 0) IMToken(mToken).mint(ttgVault, excessOwedM_); // Mint M to TTG Vault.

        // NOTE: Above functionality already has access to `currentIndex()`, and since the completion of the collateral
        //       update can result in a new rate, we should update the index here to lock in that rate.
        // NOTE: With the current rate models, the minter rate does not depend on anything in the Minter Gateway
        //       or mToken, so we can update the minter rate and index here.
        index_ = super.updateIndex(); // Update minter index and rate.

        // NOTE: Given the current implementation of the mToken transfers and its rate model, while it is possible for
        //       the above mint to already have updated the mToken index if M was minted to an earning account, we want
        //       to ensure the rate provided by the mToken's rate model is locked in.
        IMToken(mToken).updateIndex(); // Update earning index and rate.
    }

    /* ============ View/Pure Functions ============ */

    /// @inheritdoc IMinterGateway
    function totalActiveOwedM() public view returns (uint240) {
        return _getPresentAmount(principalOfTotalActiveOwedM);
    }

    /// @inheritdoc IMinterGateway
    function totalOwedM() external view returns (uint240) {
        unchecked {
            // NOTE: This can never overflow since the `mint` functions caps the principal of total owed M (active and
            //       inactive) to `type(uint112).max`. Thus, there can never be enough inactive owed M (which is an
            //       accumulations principal of active owed M values converted to present values at previous and lower
            //       indices) or active owed M to overflow this.
            return totalActiveOwedM() + totalInactiveOwedM;
        }
    }

    /// @inheritdoc IMinterGateway
    function excessOwedM() public view returns (uint240 excessOwedM_) {
        // NOTE: Can safely cast to `uint240` since we know M Token totalSupply constraints.
        uint240 totalMSupply_ = uint240(IMToken(mToken).totalSupply());

        uint240 totalOwedM_ = _getPresentAmountRoundedDown(principalOfTotalActiveOwedM, currentIndex()) +
            totalInactiveOwedM;

        unchecked {
            if (totalOwedM_ > totalMSupply_) return totalOwedM_ - totalMSupply_;
        }
    }

    /// @inheritdoc IMinterGateway
    function minterRate() external view returns (uint32) {
        return _latestRate;
    }

    /// @inheritdoc IMinterGateway
    function isActiveMinter(address minter_) external view returns (bool) {
        return _minterStates[minter_].isActive;
    }

    /// @inheritdoc IMinterGateway
    function isDeactivatedMinter(address minter_) external view returns (bool) {
        return _minterStates[minter_].isDeactivated;
    }

    /// @inheritdoc IMinterGateway
    function isFrozenMinter(address minter_) external view returns (bool) {
        return block.timestamp < _minterStates[minter_].frozenUntilTimestamp;
    }

    /// @inheritdoc IMinterGateway
    function principalOfActiveOwedMOf(address minter_) public view returns (uint112) {
        // NOTE: This should also include the principal value of unavoidable penalities. But then it would be very, if
        //       not impossible, to determine the `principalOfTotalActiveOwedM` to the same standards.
        return
            _minterStates[minter_].isActive
                ? uint112(_rawOwedM[minter_]) // Treat rawOwedM as principal since minter is active.
                : 0;
    }

    /// @inheritdoc IMinterGateway
    function activeOwedMOf(address minter_) public view returns (uint240) {
        // NOTE: This should also include the present value of unavoidable penalities. But then it would be very, if
        //       not impossible, to determine the `totalActiveOwedM` to the same standards.
        return
            _minterStates[minter_].isActive
                ? _getPresentAmount(uint112(_rawOwedM[minter_])) // Treat rawOwedM as principal since minter is active.
                : 0;
    }

    /// @inheritdoc IMinterGateway
    function maxAllowedActiveOwedMOf(address minter_) public view returns (uint256) {
        // NOTE: Since `mintRatio()` is capped at 650% (i.e. 65_000) this cannot overflow.
        unchecked {
            return _minterStates[minter_].isActive ? (uint256(collateralOf(minter_)) * mintRatio()) / ONE : 0;
        }
    }

    /// @inheritdoc IMinterGateway
    function inactiveOwedMOf(address minter_) public view returns (uint240) {
        // Treat rawOwedM as present amount since minter is inactive.
        return _minterStates[minter_].isActive ? 0 : _rawOwedM[minter_];
    }

    /// @inheritdoc IMinterGateway
    function collateralOf(address minter_) public view returns (uint240) {
        // If collateral was not updated by the deadline, assume that minter's collateral is zero.
        if (block.timestamp >= collateralExpiryTimestampOf(minter_)) return 0;

        uint240 totalPendingRetrievals_ = _minterStates[minter_].totalPendingRetrievals;
        uint240 collateral_ = _minterStates[minter_].collateral;

        // If the minter's total pending retrievals is greater than their collateral, then their collateral is zero.
        if (totalPendingRetrievals_ >= collateral_) return 0;

        unchecked {
            return collateral_ - totalPendingRetrievals_;
        }
    }

    /// @inheritdoc IMinterGateway
    function collateralUpdateTimestampOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].updateTimestamp;
    }

    /// @inheritdoc IMinterGateway
    function collateralPenaltyDeadlineOf(address minter_) external view returns (uint40) {
        MinterState storage minterState_ = _minterStates[minter_];
        uint32 updateCollateralInterval_ = updateCollateralInterval();

        (, uint40 missedUntil_) = _getMissedCollateralUpdateParameters(
            minterState_.updateTimestamp,
            minterState_.penalizedUntilTimestamp,
            updateCollateralInterval_
        );

        return missedUntil_ + updateCollateralInterval_;
    }

    /// @inheritdoc IMinterGateway
    function collateralExpiryTimestampOf(address minter_) public view returns (uint40) {
        unchecked {
            return _minterStates[minter_].updateTimestamp + updateCollateralInterval();
        }
    }

    /// @inheritdoc IMinterGateway
    function penalizedUntilOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].penalizedUntilTimestamp;
    }

    /// @inheritdoc IMinterGateway
    function getPenaltyForMissedCollateralUpdates(address minter_) external view returns (uint240) {
        uint112 penaltyPrincipal_ = _getPenaltyPrincipalForMissedCollateralUpdates(minter_);

        return (penaltyPrincipal_ == 0) ? 0 : _getPresentAmount(penaltyPrincipal_);
    }

    /// @inheritdoc IMinterGateway
    function getUpdateCollateralDigest(
        address minter_,
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        uint256 timestamp_
    ) external view returns (bytes32) {
        return _getUpdateCollateralDigest(minter_, collateral_, retrievalIds_, metadataHash_, timestamp_);
    }

    /// @inheritdoc IMinterGateway
    function mintProposalOf(
        address minter_
    ) external view returns (uint48 mintId_, uint40 createdAt_, address destination_, uint240 amount_) {
        mintId_ = _mintProposals[minter_].id;
        createdAt_ = _mintProposals[minter_].createdAt;
        destination_ = _mintProposals[minter_].destination;
        amount_ = _mintProposals[minter_].amount;
    }

    /// @inheritdoc IMinterGateway
    function pendingCollateralRetrievalOf(address minter_, uint256 retrievalId_) external view returns (uint240) {
        return
            _minterStates[minter_].isDeactivated
                ? 0
                : _pendingCollateralRetrievals[minter_][UIntMath.safe48(retrievalId_)];
    }

    /// @inheritdoc IMinterGateway
    function totalPendingCollateralRetrievalOf(address minter_) external view returns (uint240) {
        return _minterStates[minter_].isDeactivated ? 0 : _minterStates[minter_].totalPendingRetrievals;
    }

    /// @inheritdoc IMinterGateway
    function frozenUntilOf(address minter_) external view returns (uint40) {
        return _minterStates[minter_].frozenUntilTimestamp;
    }

    /* ============ TTG Registrar Reader Functions ============ */

    /// @inheritdoc IMinterGateway
    function isMinterApproved(address minter_) public view returns (bool) {
        return TTGRegistrarReader.isApprovedMinter(ttgRegistrar, minter_);
    }

    /// @inheritdoc IMinterGateway
    function isValidatorApprovedByTTG(address validator_) public view returns (bool) {
        return TTGRegistrarReader.isApprovedValidator(ttgRegistrar, validator_);
    }

    /// @inheritdoc IMinterGateway
    function updateCollateralInterval() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getUpdateCollateralInterval(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function updateCollateralValidatorThreshold() public view returns (uint256) {
        return TTGRegistrarReader.getUpdateCollateralValidatorThreshold(ttgRegistrar);
    }

    /// @inheritdoc IMinterGateway
    function mintRatio() public view returns (uint32) {
        // NOTE: It is possible for the mint ratio to be greater than 100%, but capped at 650%.
        return UIntMath.min32(MAX_MINT_RATIO, UIntMath.bound32(TTGRegistrarReader.getMintRatio(ttgRegistrar)));
    }

    /// @inheritdoc IMinterGateway
    function mintDelay() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMintDelay(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function mintTTL() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMintTTL(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function minterFreezeTime() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getMinterFreezeTime(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function penaltyRate() public view returns (uint32) {
        return UIntMath.bound32(TTGRegistrarReader.getPenaltyRate(ttgRegistrar));
    }

    /// @inheritdoc IMinterGateway
    function rateModel() public view returns (address) {
        return TTGRegistrarReader.getMinterRateModel(ttgRegistrar);
    }

    /// @inheritdoc IContinuousIndexing
    function currentIndex() public view override(ContinuousIndexing, IContinuousIndexing) returns (uint128) {
        // NOTE: Safe to use unchecked here, since `block.timestamp` is always greater than `latestUpdateTimestamp`.
        unchecked {
            return
                // NOTE: Cap the index to `type(uint128).max` to prevent overflow in present value math.
                UIntMath.bound128(
                    ContinuousIndexingMath.multiplyIndicesUp(
                        latestIndex,
                        ContinuousIndexingMath.getContinuousIndex(
                            ContinuousIndexingMath.convertFromBasisPoints(_latestRate),
                            uint32(block.timestamp - latestUpdateTimestamp)
                        )
                    )
                );
        }
    }

    /* ============ Internal Interactive Functions ============ */

    /**
     * @dev   Imposes penalty on an active minter. Calling this for an inactive minter will break accounting.
     * @param minter_                 The address of the minter.
     * @param principalOfPenaltyBase_ The principal of the base for penalization.
     */
    function _imposePenalty(address minter_, uint152 principalOfPenaltyBase_) internal {
        if (principalOfPenaltyBase_ == 0) return;

        uint32 penaltyRate_ = penaltyRate();

        if (penaltyRate_ == 0) return;

        unchecked {
            uint256 penaltyPrincipal_ = (uint256(principalOfPenaltyBase_) * penaltyRate_) / ONE;

            // As an edge case precaution, cap the penalty principal such that the resulting principal of total active
            // owed M plus the penalty principal is not greater than the max uint112.
            uint256 newPrincipalOfTotalActiveOwedM_ = principalOfTotalActiveOwedM + penaltyPrincipal_;

            if (newPrincipalOfTotalActiveOwedM_ > type(uint112).max) {
                penaltyPrincipal_ = type(uint112).max - principalOfTotalActiveOwedM;
                newPrincipalOfTotalActiveOwedM_ = type(uint112).max;
            }

            // Calculate and add penalty principal to total minter's principal of active owed M
            principalOfTotalActiveOwedM = uint112(newPrincipalOfTotalActiveOwedM_);

            _rawOwedM[minter_] += uint112(penaltyPrincipal_); // Treat rawOwedM as principal since minter is active.

            emit PenaltyImposed(minter_, uint112(penaltyPrincipal_), _getPresentAmount(uint112(penaltyPrincipal_)));
        }
    }

    /**
     * @dev   Imposes penalty if minter missed collateral updates.
     * @param minter_ The address of the minter.
     */
    function _imposePenaltyIfMissedCollateralUpdates(address minter_) internal {
        uint32 updateCollateralInterval_ = updateCollateralInterval();

        MinterState storage minterState_ = _minterStates[minter_];

        (uint40 missedIntervals_, uint40 missedUntil_) = _getMissedCollateralUpdateParameters(
            minterState_.updateTimestamp,
            minterState_.penalizedUntilTimestamp,
            updateCollateralInterval_
        );

        if (missedIntervals_ == 0) return;

        // Save until when the minter has been penalized for missed intervals to prevent double penalizing them.
        _minterStates[minter_].penalizedUntilTimestamp = missedUntil_;

        uint112 principalOfActiveOwedM_ = principalOfActiveOwedMOf(minter_);

        if (principalOfActiveOwedM_ == 0) return;

        _imposePenalty(minter_, uint152(principalOfActiveOwedM_) * missedIntervals_);
    }

    /**
     * @dev   Imposes penalty if minter is undercollateralized.
     * @param minter_ The address of the minter
     */
    function _imposePenaltyIfUndercollateralized(address minter_) internal {
        uint112 principalOfActiveOwedM_ = principalOfActiveOwedMOf(minter_);

        if (principalOfActiveOwedM_ == 0) return;

        uint256 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);

        // If the minter's max allowed active owed M is greater than `type(uint240).max`, then it's definitely greater
        // than the max possible active owed M for the minter, which is capped at `type(uint240).max`.
        if (maxAllowedActiveOwedM_ >= type(uint240).max) return;

        // NOTE: Round the principal down in favor of the protocol since this is a max applied to the minter.
        uint112 principalOfMaxAllowedActiveOwedM_ = _getPrincipalAmountRoundedDown(uint240(maxAllowedActiveOwedM_));

        if (principalOfMaxAllowedActiveOwedM_ >= principalOfActiveOwedM_) return;

        unchecked {
            _imposePenalty(minter_, principalOfActiveOwedM_ - principalOfMaxAllowedActiveOwedM_);
        }
    }

    /**
     * @dev    Repays active minter's owed M.
     * @param  minter_             The address of the minter.
     * @param  maxPrincipalAmount_ The maximum principal amount of active owed M to repay.
     * @param  maxAmount_          The maximum amount of active owed M to repay.
     * @return principalAmount_    The principal amount of active owed M that was actually repaid.
     * @return amount_             The amount of active owed M that was actually repaid.
     */
    function _repayForActiveMinter(
        address minter_,
        uint112 maxPrincipalAmount_,
        uint240 maxAmount_
    ) internal returns (uint112 principalAmount_, uint240 amount_) {
        principalAmount_ = UIntMath.min112(principalOfActiveOwedMOf(minter_), maxPrincipalAmount_);
        amount_ = _getPresentAmount(principalAmount_);

        if (amount_ > maxAmount_) revert ExceedsMaxRepayAmount(amount_, maxAmount_);

        unchecked {
            // Treat rawOwedM as principal since `principalAmount_` would only be non-zero for an active minter.
            _rawOwedM[minter_] -= principalAmount_;
            principalOfTotalActiveOwedM -= principalAmount_;
        }
    }

    /**
     * @dev    Repays inactive minter's owed M.
     * @param  minter_    The address of the minter.
     * @param  maxAmount_ The maximum amount of inactive owed M to repay.
     * @return amount_    The amount of inactive owed M that was actually repaid.
     */
    function _repayForInactiveMinter(address minter_, uint240 maxAmount_) internal returns (uint240 amount_) {
        amount_ = UIntMath.min240(inactiveOwedMOf(minter_), maxAmount_);

        unchecked {
            // Treat rawOwedM as present amount since `amount_` would only be non-zero for an inactive minter.
            _rawOwedM[minter_] -= amount_;
            totalInactiveOwedM -= amount_;
        }
    }

    /**
     * @dev    Resolves the collateral retrieval IDs and updates the total pending collateral retrieval amount.
     * @param  minter_                           The address of the minter.
     * @param  retrievalIds_                     The list of outstanding collateral retrieval IDs to resolve.
     * @return totalResolvedCollateralRetrieval_ The total amount of collateral retrieval resolved.
     */
    function _resolvePendingRetrievals(
        address minter_,
        uint256[] calldata retrievalIds_
    ) internal returns (uint240 totalResolvedCollateralRetrieval_) {
        for (uint256 index_; index_ < retrievalIds_.length; ++index_) {
            uint48 retrievalId_ = UIntMath.safe48(retrievalIds_[index_]);
            uint240 pendingCollateralRetrieval_ = _pendingCollateralRetrievals[minter_][retrievalId_];

            if (pendingCollateralRetrieval_ == 0) continue;

            unchecked {
                // NOTE: The `proposeRetrieval` function already ensures that the sum of all
                // `_pendingCollateralRetrievals` is not larger than `type(uint240).max`.
                totalResolvedCollateralRetrieval_ += pendingCollateralRetrieval_;
            }

            delete _pendingCollateralRetrievals[minter_][retrievalId_];

            emit RetrievalResolved(retrievalId_, minter_);
        }

        unchecked {
            // NOTE: The `proposeRetrieval` function already ensures that `totalPendingRetrievals` is the sum of all
            // `_pendingCollateralRetrievals`.
            _minterStates[minter_].totalPendingRetrievals -= totalResolvedCollateralRetrieval_;
        }
    }

    /**
     * @dev   Updates the collateral amount and update timestamp for the minter.
     * @param minter_       The address of the minter.
     * @param amount_       The amount of collateral.
     * @param newTimestamp_ The timestamp of the collateral update.
     */
    function _updateCollateral(address minter_, uint240 amount_, uint40 newTimestamp_) internal {
        uint40 lastUpdateTimestamp_ = _minterStates[minter_].updateTimestamp;

        // MinterGateway already has more recent collateral update
        if (newTimestamp_ <= lastUpdateTimestamp_) revert StaleCollateralUpdate(newTimestamp_, lastUpdateTimestamp_);

        _minterStates[minter_].collateral = amount_;
        _minterStates[minter_].updateTimestamp = newTimestamp_;
    }

    /* ============ Internal View/Pure Functions ============ */

    /**
     * @dev    Returns the penalization base and the penalized until timestamp.
     * @param  lastUpdateTimestamp_ The last timestamp at which the minter updated their collateral.
     * @param  lastPenalizedUntil_  The timestamp before which the minter shouldn't be penalized for missed updates.
     * @param  updateInterval_      The update collateral interval.
     * @return missedIntervals_     The number of missed update intervals.
     * @return missedUntil_         The timestamp until which `missedIntervals_` covers,
     *                              even if `missedIntervals_` is 0.
     */
    function _getMissedCollateralUpdateParameters(
        uint40 lastUpdateTimestamp_,
        uint40 lastPenalizedUntil_,
        uint32 updateInterval_
    ) internal view returns (uint40 missedIntervals_, uint40 missedUntil_) {
        uint40 penalizeFrom_ = UIntMath.max40(lastUpdateTimestamp_, lastPenalizedUntil_);

        // If brand new minter or `updateInterval_` is 0, then there is no missed interval charge at all.
        if (lastUpdateTimestamp_ == 0 || updateInterval_ == 0) return (0, penalizeFrom_);

        uint40 timeElapsed_ = uint40(block.timestamp) - penalizeFrom_;

        if (timeElapsed_ < updateInterval_) return (0, penalizeFrom_);

        missedIntervals_ = timeElapsed_ / updateInterval_;

        // NOTE: Cannot really overflow a `uint40` since `missedIntervals_ * updateInterval_ <= timeElapsed_`.
        missedUntil_ = penalizeFrom_ + (missedIntervals_ * updateInterval_);
    }

    /**
     * @dev    Returns the principal penalization base for a minter's missed collateral updates.
     * @param  minter_ The address of the minter.
     * @return The penalty principal.
     */
    function _getPenaltyPrincipalForMissedCollateralUpdates(address minter_) internal view returns (uint112) {
        uint112 principalOfActiveOwedM_ = principalOfActiveOwedMOf(minter_);

        if (principalOfActiveOwedM_ == 0) return 0;

        uint32 penaltyRate_ = penaltyRate();

        if (penaltyRate_ == 0) return 0;

        MinterState storage minterState_ = _minterStates[minter_];

        (uint40 missedIntervals_, ) = _getMissedCollateralUpdateParameters(
            minterState_.updateTimestamp,
            minterState_.penalizedUntilTimestamp,
            updateCollateralInterval()
        );

        if (missedIntervals_ == 0) return 0;

        unchecked {
            // As an edge case precaution, cap the penalty principal to type(uint112).max.
            return UIntMath.bound112((uint256(principalOfActiveOwedM_) * missedIntervals_ * penaltyRate_) / ONE);
        }
    }

    /**
     * @dev    Returns the present amount (rounded up) given the principal amount, using the current index.
     *         All present amounts are rounded up in favor of the protocol, since they are owed.
     * @param  principalAmount_ The principal amount.
     * @return The present amount.
     */
    function _getPresentAmount(uint112 principalAmount_) internal view returns (uint240) {
        return _getPresentAmountRoundedUp(principalAmount_, currentIndex());
    }

    /**
     * @dev    Returns the EIP-712 digest for updateCollateral method.
     * @param  minter_       The address of the minter.
     * @param  collateral_   The amount of collateral.
     * @param  retrievalIds_ The list of outstanding collateral retrieval IDs to resolve.
     * @param  metadataHash_ The hash of metadata of the collateral update, reserved for future informational use.
     * @param  timestamp_    The timestamp of the collateral update.
     * @return The EIP-712 digest.
     */
    function _getUpdateCollateralDigest(
        address minter_,
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        uint256 timestamp_
    ) internal view returns (bytes32) {
        return
            _getDigest(
                keccak256(
                    abi.encode(
                        UPDATE_COLLATERAL_TYPEHASH,
                        minter_,
                        collateral_,
                        keccak256(abi.encodePacked(retrievalIds_)),
                        metadataHash_,
                        timestamp_
                    )
                )
            );
    }

    /// @dev Returns the current rate from the rate model contract.
    function _rate() internal view override returns (uint32 rate_) {
        (bool success_, bytes memory returnData_) = rateModel().staticcall(
            abi.encodeWithSelector(IRateModel.rate.selector)
        );

        rate_ = (success_ && returnData_.length >= 32) ? UIntMath.bound32(abi.decode(returnData_, (uint256))) : 0;
    }

    /**
     * @dev   Reverts if minter is frozen by validator.
     * @param minter_ The address of the minter
     */
    function _revertIfFrozenMinter(address minter_) internal view {
        if (block.timestamp < _minterStates[minter_].frozenUntilTimestamp) revert FrozenMinter();
    }

    /**
     * @dev   Reverts if minter is inactive.
     * @param minter_ The address of the minter
     */
    function _revertIfInactiveMinter(address minter_) internal view {
        if (!_minterStates[minter_].isActive) revert InactiveMinter();
    }

    /**
     * @dev   Reverts if validator is not approved.
     * @param validator_ The address of the validator
     */
    function _revertIfNotApprovedValidator(address validator_) internal view {
        if (!isValidatorApprovedByTTG(validator_)) revert NotApprovedValidator();
    }

    /**
     * @dev   Reverts if minter position will be undercollateralized after changes.
     * @param minter_          The address of the minter
     * @param additionalOwedM_ The amount of additional owed M the action will add to minter's position
     */
    function _revertIfUndercollateralized(address minter_, uint240 additionalOwedM_) internal view {
        uint256 maxAllowedActiveOwedM_ = maxAllowedActiveOwedMOf(minter_);

        // If the minter's max allowed active owed M is greater than the max uint240, then it's definitely greater than
        // the max possible active owed M for the minter, which is capped at the max uint240.
        if (maxAllowedActiveOwedM_ >= type(uint240).max) return;

        unchecked {
            uint256 finalActiveOwedM_ = uint256(activeOwedMOf(minter_)) + additionalOwedM_;

            if (finalActiveOwedM_ > maxAllowedActiveOwedM_) {
                revert Undercollateralized(finalActiveOwedM_, maxAllowedActiveOwedM_);
            }
        }
    }

    /**
     * @dev    Checks that enough valid unique signatures were provided.
     * @param  minter_       The address of the minter.
     * @param  collateral_   The amount of collateral.
     * @param  retrievalIds_ The list of outstanding collateral retrieval IDs to resolve.
     * @param  metadataHash_ The hash of metadata of the collateral update, reserved for future informational use.
     * @param  validators_   The list of validators.
     * @param  timestamps_   The list of validator timestamps for the collateral update signatures.
     * @param  signatures_   The list of signatures.
     * @return minTimestamp_ The minimum timestamp across all valid timestamps with valid signatures.
     */
    function _verifyValidatorSignatures(
        address minter_,
        uint256 collateral_,
        uint256[] calldata retrievalIds_,
        bytes32 metadataHash_,
        address[] calldata validators_,
        uint256[] calldata timestamps_,
        bytes[] calldata signatures_
    ) internal view returns (uint40 minTimestamp_) {
        uint256 threshold_ = updateCollateralValidatorThreshold();

        minTimestamp_ = uint40(block.timestamp);

        // Stop processing if there are no more signatures or `threshold_` is reached.
        for (uint256 index_; index_ < signatures_.length && threshold_ > 0; ++index_) {
            unchecked {
                // Check that validator address is unique and not accounted for
                // NOTE: We revert here because this failure is entirely within the minter's control.
                if (index_ > 0 && validators_[index_] <= validators_[index_ - 1]) revert InvalidSignatureOrder();
            }

            // Check that validator is approved by TTG.
            if (!isValidatorApprovedByTTG(validators_[index_])) continue;

            // Check that the timestamp is not 0.
            if (timestamps_[index_] == 0) revert ZeroTimestamp();

            // Check that the timestamp is not in the future.
            if (timestamps_[index_] > uint40(block.timestamp)) revert FutureTimestamp();

            // NOTE: Need to store the variable here to avoid a stack too deep error.
            bytes32 digest_ = _getUpdateCollateralDigest(
                minter_,
                collateral_,
                retrievalIds_,
                metadataHash_,
                timestamps_[index_]
            );

            // Check that ECDSA or ERC1271 signatures for given digest are valid.
            if (!SignatureChecker.isValidSignature(validators_[index_], digest_, signatures_[index_])) continue;

            // Find minimum between all valid timestamps for valid signatures.
            minTimestamp_ = UIntMath.min40(minTimestamp_, uint40(timestamps_[index_]));

            unchecked {
                --threshold_;
            }
        }

        // NOTE: Due to STACK_TOO_DEEP issues, we need to refetch `requiredThreshold_` and compute the number of valid
        //       signatures here, in order to emit the correct error message. However, the code will only reach this
        //       point to inevitably revert, so the gas cost is not much of a concern.
        if (threshold_ > 0) {
            uint256 requiredThreshold_ = updateCollateralValidatorThreshold();

            unchecked {
                // NOTE: By this point, it is already established that `threshold_` is less than `requiredThreshold_`.
                revert NotEnoughValidSignatures(requiredThreshold_ - threshold_, requiredThreshold_);
            }
        }
    }
}
