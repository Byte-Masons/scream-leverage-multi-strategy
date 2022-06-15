// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IStrategy.sol";
import "./interfaces/IERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @notice Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract ReaperVaultV2 is IERC4626, ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;

    struct StrategyParams {
        uint256 activation; // Activation block.timestamp
        uint256 allocBPS; // Allocation in BPS of vault's total assets
        uint256 allocated; // Amount of capital allocated to this strategy
        uint256 gains; // Total returns that Strategy has realized for Vault
        uint256 losses; // Total losses that Strategy has realized for Vault
        uint256 lastReport; // block.timestamp of the last time a report occured
    }

    mapping(address => StrategyParams) public strategies;  // mapping strategies to their strategy parameters
    address[] public withdrawalQueue; // Ordering that `withdraw` uses to determine which strategies to pull funds from
    uint256 public constant DEGRADATION_COEFFICIENT = 10 ** 18; // The unit for calculating profit degradation.
    uint256 public constant PERCENT_DIVISOR = 10000; // Basis point unit, for calculating slippage and strategy allocations
    uint256 public tvlCap; // The maximum amount of assets the vault can hold while still allowing deposits
    uint256 public totalAllocBPS; // Sum of allocBPS across all strategies (in BPS, <= 10k)
    uint256 public totalAllocated; // Amount of tokens that have been allocated to all strategies
    uint256 public lastReport; // block.timestamp of last report from any strategy
    uint256 public constructionTime; // The time the vault was deployed - for front-end
    bool public emergencyShutdown; // Emergency shutdown - when true funds are pulled out of strategies to the vault
    address public immutable asset; // The asset the vault accepts and looks to maximize.
    uint256 public withdrawMaxLoss = 1; // Max slippage(loss) allowed when withdrawing, in BPS (0.01%)
    uint256 public lockedProfitDegradation; // rate per block of degradation. DEGRADATION_COEFFICIENT is 100% per block
    uint256 public  lockedProfit; // how much profit is locked and cant be withdrawn

    /**
     * @notice simple mappings used to determine PnL denominated in LP tokens,
     * as well as keep a generalized history of a user's protocol usage.
     */
    mapping(address => uint256) public cumulativeDeposits;
    mapping(address => uint256) public cumulativeWithdrawals;

    event TvlCapUpdated(uint256 newTvlCap);
    event DepositsIncremented(address user, uint256 amount, uint256 total);
    event WithdrawalsIncremented(address user, uint256 amount, uint256 total);
    event LockedProfitDegradationUpdated(uint256 degradation);
    event StrategyReported(
        address indexed strategy,
        int256 roi,
        uint256 repayment,
        uint256 gains,
        uint256 losses,
        uint256 allocated,
        uint256 allocBPS 
    );

    /**
     * @notice Initializes the vault's own 'RF' asset.
     * This asset is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _asset the asset to maximize.
     * @param _name the name of the vault asset.
     * @param _symbol the symbol of the vault asset.
     * @param _tvlCap initial deposit cap for scaling TVL safely.
     */
    constructor(
        address _asset,
        string memory _name,
        string memory _symbol,
        uint256 _tvlCap
    ) ERC20(string(_name), string(_symbol)) {
        asset = _asset;
        constructionTime = block.timestamp;
        lastReport = block.timestamp;
        tvlCap = _tvlCap;
        lockedProfitDegradation = DEGRADATION_COEFFICIENT * 46 / 10 ** 6; // 6 hours in blocks
    }

    /**
     * @notice It calculates the total underlying value of {asset} held by the system.
     * It takes into account the vault contract balance, and the balance deployed across
     * all the strategies.
     * @return totalManagedAssets - the total amount of assets managed by the vault.
     */
    function totalAssets() public view returns (uint256) {
        return IERC20Metadata(asset).balanceOf(address(this)) + totalAllocated - _calculateLockedProfit();
    }

    /**
     * @notice It calculates the amount of locked profit from recent harvests.
     * @return the amount of locked profit.
     */
    function _calculateLockedProfit() internal view returns (uint256) {
        uint256 lockedFundsRatio = (block.timestamp - lastReport) * lockedProfitDegradation;

        if(lockedFundsRatio < DEGRADATION_COEFFICIENT) {
            return lockedProfit - (
                lockedFundsRatio
                * lockedProfit
                / DEGRADATION_COEFFICIENT
            );
        } else {
            return 0;
        }
    }

    /**
     * @notice The amount of shares that the Vault would exchange for the amount of assets provided,
     * in an ideal scenario where all the conditions are met.
     * @param assets The amount of underlying assets to convert to shares.
     * @return shares - the amount of shares given for the amount of assets.
     */
    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        uint256 _totalAssets = totalAssets();
        if (_totalAssets == 0 || _totalSupply == 0) return assets;
        return assets * _totalSupply / _totalAssets;
    }

    /**
     * @notice The amount of assets that the Vault would exchange for the amount of shares provided,
     * in an ideal scenario where all the conditions are met.
     * @param shares The amount of shares to convert to underlying assets.
     * @return assets - the amount of assets given for the amount of shares.
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return shares; // Initially the price is 1:1
        return shares * totalAssets() / _totalSupply;
    }

    /**
     * @notice Maximum amount of the underlying asset that can be deposited into the Vault for the receiver, 
     * through a deposit call.
     * @param receiver The depositor, unused in this case but here as part of the ERC4626 spec.
     * @return maxAssets - the maximum depositable assets.
     */
    function maxDeposit(address receiver) public view returns (uint256) {
        uint256 totalAssets = totalAssets();
        if (totalAssets > tvlCap) {
            return 0;
        }
        return tvlCap - totalAssets;
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their deposit at the current block, 
     * given current on-chain conditions. 
     * @param assets The amount of assets to deposit.
     * @return shares - the amount of shares given for the amount of assets.
     */
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    /**
     * @notice A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(IERC20Metadata(asset).balanceOf(msg.sender), msg.sender);
    }

    /**
     * @notice The entrypoint of funds into the system. People deposit with this function
     * into the vault.
     * @param assets The amount of assets to deposit
     * @param receiver The receiver of the minted shares
     * @return shares - the amount of shares issued from the deposit.
     */
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(!emergencyShutdown);
        require(assets != 0, "please provide amount");
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");
        shares = previewDeposit(assets);

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);
        
        _mint(receiver, shares);
        incrementDeposits(assets, receiver);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Maximum amount of shares that can be minted from the Vault for the receiver, through a mint call.
     * @param receiver The minter, unused in this case but here as part of the ERC4626 spec.
     * @return shares - the maximum amount of shares issued from calling mint.
     */
    function maxMint(address receiver) public view virtual returns (uint256) {
        return convertToShares(maxDeposit(address(0)));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, 
     * given current on-chain conditions.
     * @param shares The amount of shares to mint.
     * @return assets - the amount of assets given for the amount of shares.
     */
    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 assets = convertToAssets(shares);
        if (assets == 0 && totalAssets() == 0) return shares;
        return assets;
    }

    /**
     * @notice Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
     * @param shares The amount of shares to mint.
     * @param receiver The receiver of the minted shares.
     * @return assets - the amount of assets transferred from the mint.
     */
    function mint(uint256 shares, address receiver) public returns (uint256) {
        require(!emergencyShutdown);
        require(shares != 0, "please provide amount");
        uint256 assets = previewMint(shares);
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");

        if (totalAssets() == 0) assets = shares;

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        incrementDeposits(assets, receiver);
        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    /**
     * @notice Maximum amount of the underlying asset that can be withdrawn from the owner balance in the Vault,
     * through a withdraw call.
     * @param owner The owner of the shares to withdraw.
     * @return maxAssets - the maximum amount of assets transferred from calling withdraw.
     */
    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     * @param assets The amount of assets to withdraw.
     * @return shares - the amount of shares burned for the amount of assets.
     */
    function previewWithdraw(uint256 assets) public view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 shares = convertToShares(assets);
        return shares;
    }

    /**
     * @notice Burns shares from owner and sends exactly assets of underlying tokens to receiver.
     * @param assets The amount of assets to withdraw.
     * @param receiver The receiver of the withdrawn assets.
     * @param owner The owner of the shares to withdraw.
     * @return shares - the amount of shares burned.
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets > 0, "please provide amount");
        shares = previewWithdraw(assets);
        _withdraw(assets, shares, receiver, owner);
        return shares;
    }

    /**
     * @notice Helper function used by both withdraw and redeem to withdraw assets.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares to burn.
     * @param receiver The receiver of the withdrawn assets.
     * @param owner The owner of the shares to withdraw.
     * @return assets - the amount of assets withdrawn.
     */
    function _withdraw(uint256 assets, uint256 shares, address receiver, address owner) internal returns (uint256) {
        _burn(owner, shares);

        if (assets > IERC20Metadata(asset).balanceOf(address(this))) {
            uint256 totalLoss = 0;
            uint256 queueLength = withdrawalQueue.length;
            uint256 vaultBalance = 0;
            for (uint256 i = 0; i < queueLength; i++) {
                vaultBalance = IERC20Metadata(asset).balanceOf(address(this));
                if (assets <= vaultBalance) {
                    break;
                }

                address stratAddr = withdrawalQueue[i];
                uint256 strategyBal = strategies[stratAddr].allocated;
                if (strategyBal == 0) {
                    continue;
                }

                uint256 remaining = assets - vaultBalance;
                uint256 loss = IStrategy(stratAddr).withdraw(Math.min(remaining, strategyBal));
                uint256 actualWithdrawn = IERC20Metadata(asset).balanceOf(address(this)) - vaultBalance;

                // Withdrawer incurs any losses from withdrawing as reported by strat
                if (loss != 0) {
                    assets -= loss;
                    totalLoss += loss;
                    _reportLoss(stratAddr, loss);
                }

                strategies[stratAddr].allocated -= actualWithdrawn;
                totalAllocated -= actualWithdrawn;
            }

            vaultBalance = IERC20Metadata(asset).balanceOf(address(this));
            if (assets > vaultBalance) {
                assets = vaultBalance;
            }

            require(totalLoss <= ((assets + totalLoss) * withdrawMaxLoss) / PERCENT_DIVISOR);
        }

        IERC20Metadata(asset).safeTransfer(receiver, assets);
        incrementWithdrawals(assets, owner);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    /**
     * @notice Maximum amount of Vault shares that can be redeemed from the owner balance in the Vault, 
     * through a redeem call.
     * @param owner The owner of the shares to redeem.
     * @return maxShares - the amount of redeemable shares.
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their redeemption at the current block,
     * given current on-chain conditions.
     * @param shares The amount of shares to redeem.
     * @return assets - the amount of assets redeemed from the amount of shares.
     */
    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    /**
     * @notice A helper function to call redeem() with all the sender's funds.
     */
    function redeemAll() external {
        redeem(balanceOf(msg.sender), msg.sender, msg.sender);
    }

    /**
     * @notice Burns exactly shares from owner and sends assets of underlying tokens to receiver.
     * @param shares The amount of shares to redeem.
     * @param receiver The receiver of the redeemed assets.
     * @param owner The owner of the shares to redeem.
     * @return assets - the amount of assets redeemed.
     */
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        require(shares > 0, "please provide amount");
        assets = previewRedeem(shares);
        return _withdraw(assets, shares, receiver, owner);
    }

    /**
     * @notice Adds a new strategy to the vault with a given allocation amount in basis points.
     * @param strategy The strategy to add.
     * @param allocBPS The strategy allocation in basis points.
     */
    function addStrategy(address strategy, uint256 allocBPS) external onlyOwner {
        require(!emergencyShutdown);
        require(strategy != address(0));
        require(strategies[strategy].activation == 0);
        require(address(this) == IStrategy(strategy).vault());
        require(asset == IStrategy(strategy).want());
        require(allocBPS + totalAllocBPS <= PERCENT_DIVISOR);

        strategies[strategy] = StrategyParams({
            activation: block.timestamp,
            allocBPS: allocBPS,
            allocated: 0,
            gains: 0,
            losses: 0,
            lastReport: block.timestamp
        });

        totalAllocBPS += allocBPS;
        withdrawalQueue.push(strategy);
    }

    /**
     * @notice Updates the allocation points for a given strategy.
     * @param strategy The strategy to update.
     * @param allocBPS The strategy allocation in basis points.
     */
    function updateStrategyAllocBPS(address strategy, uint256 allocBPS) external onlyOwner {
        require(strategies[strategy].activation != 0);
        totalAllocBPS -= strategies[strategy].allocBPS;
        strategies[strategy].allocBPS = allocBPS;
        totalAllocBPS += allocBPS;
        require(totalAllocBPS <= PERCENT_DIVISOR);
    }

    /**
     * @notice Removes any allocation to a given strategy.
     * @param strategy The strategy to revoke.
     */
    function revokeStrategy(address strategy) external {
        require(msg.sender == owner() || msg.sender == strategy);
        if (strategies[strategy].allocBPS == 0) {
            return;
        }

        totalAllocBPS -= strategies[strategy].allocBPS;
        strategies[strategy].allocBPS = 0;
    }

    /**
     * @notice Called by a strategy to determine the amount of capital that the vault is
     * able to provide it. A positive amount means that vault has excess capital to provide
     * the strategy, while a negative amount means that the strategy has a balance owing to
     * the vault.
     * @return availableCapital - the amount of capital the vault can provide the strategy.
     */
    function availableCapital() public view returns (int256) {
        address stratAddr = msg.sender;
        if (totalAllocBPS == 0 || emergencyShutdown) {
            return -int256(strategies[stratAddr].allocated);
        }

        uint256 stratMaxAllocation = (strategies[stratAddr].allocBPS * totalAssets()) / PERCENT_DIVISOR;
        uint256 stratCurrentAllocation = strategies[stratAddr].allocated;

        if (stratCurrentAllocation > stratMaxAllocation) {
            return -int256(stratCurrentAllocation - stratMaxAllocation);
        } else if (stratCurrentAllocation < stratMaxAllocation) {
            uint256 vaultMaxAllocation = (totalAllocBPS * totalAssets()) / PERCENT_DIVISOR;
            uint256 vaultCurrentAllocation = totalAllocated;

            if (vaultCurrentAllocation >= vaultMaxAllocation) {
                return 0;
            }

            uint256 available = stratMaxAllocation - stratCurrentAllocation;
            available = Math.min(available, vaultMaxAllocation - vaultCurrentAllocation);
            available = Math.min(available, IERC20Metadata(asset).balanceOf(address(this)));

            return int256(available);
        } else {
            return 0;
        }
    }

    /**
     * @notice Updates the withdrawalQueue to match the addresses and order specified.
     * @param _withdrawalQueue The new withdrawalQueue to update to.
     */
    function setWithdrawalQueue(address[] calldata _withdrawalQueue) external onlyOwner {
        uint256 queueLength = _withdrawalQueue.length;
        require(queueLength != 0);

        delete withdrawalQueue;
        for (uint256 i = 0; i < queueLength; i++) {
            address strategy = _withdrawalQueue[i];
            StrategyParams storage params = strategies[strategy];
            require(params.activation != 0);
            withdrawalQueue.push(strategy);
        }
    }

    /**
     * @notice Helper function to report a loss by a given strategy.
     * @param strategy The strategy to report the loss for.
     * @param loss The amount lost.
     */
    function _reportLoss(address strategy, uint256 loss) internal {
        StrategyParams storage stratParams = strategies[strategy];
        // Loss can only be up the amount of capital allocated to the strategy
        uint256 allocation = stratParams.allocated;
        require(loss <= allocation);

        if (totalAllocBPS != 0) {
            // reduce strat's allocBPS proportional to loss
            uint256 bpsChange = Math.min((loss * totalAllocBPS) / totalAllocated, stratParams.allocBPS);

            // If the loss is too small, bpsChange will be 0
            if (bpsChange != 0) {
                stratParams.allocBPS -= bpsChange;
                totalAllocBPS -= bpsChange;
            }
        }

        // Finally, adjust our strategy's parameters by the loss
        stratParams.losses += loss;
        stratParams.allocated -= loss;
        totalAllocated -= loss;
    }

    /**
     * @notice Helper function to report the strategy returns on a harvest.
     * @param roi The return on investment (positive or negative) given as the total amount
     * gained or lost from the harvest.
     * @param repayment The repayment of debt by the strategy.
     * @return debt - the strategy debt to the vault.
     */
    function report(int256 roi, uint256 repayment) external returns (uint256) {
        address stratAddr = msg.sender;
        StrategyParams storage strategy = strategies[stratAddr];
        require(strategy.activation != 0);
        uint256 loss = 0;
        uint256 gain = 0;

        if (roi < 0) {
            loss = uint256(-roi);
            _reportLoss(stratAddr, loss);
        } else {
            gain = uint256(roi);
            strategy.gains += uint256(roi);
        }

        int256 available = availableCapital();
        uint256 debt = 0;
        uint256 credit = 0;
        uint256 repayment;
        if (available < 0) {
            debt = uint256(-available);
            repayment = Math.min(debt, repayment);

            if (repayment != 0) {
                strategy.allocated -= repayment;
                totalAllocated -= repayment;
                debt -= repayment;
            }
        } else {
            credit = uint256(available);
            strategy.allocated += credit;
            totalAllocated += credit;
        }

        uint256 freeWantInStrat = repayment;
        if (roi > 0) {
            freeWantInStrat += uint256(roi);
        }

        if (credit > freeWantInStrat) {
            IERC20Metadata(asset).safeTransfer(stratAddr, credit - freeWantInStrat);
        } else if (credit < freeWantInStrat) {
            IERC20Metadata(asset).safeTransferFrom(stratAddr, address(this), freeWantInStrat - credit);
        }

        uint256 lockedProfitBeforeLoss = _calculateLockedProfit() + gain;
        if (lockedProfitBeforeLoss > loss) {
            lockedProfit = lockedProfitBeforeLoss - loss;
        } else {
            lockedProfit = 0;
        }

        strategy.lastReport = block.timestamp;
        lastReport = block.timestamp;

        emit StrategyReported(
            stratAddr,
            roi,
            repayment,
            strategy.gains,
            strategy.losses,
            strategy.allocated,
            strategy.allocBPS 
        );

        if (strategy.allocBPS == 0 || emergencyShutdown) {
            return IStrategy(stratAddr).balanceOf();
        }

        return debt;
    }

    /**
     * @notice Updates the withdrawMaxLoss which is the maximum allowed slippage.
     * @param _withdrawMaxLoss The new value, in basis points.
     */
    function updateWithdrawMaxLoss(uint256 _withdrawMaxLoss) external onlyOwner {
        require(_withdrawMaxLoss <= PERCENT_DIVISOR);
        withdrawMaxLoss = _withdrawMaxLoss;
    }

    /**
     * @notice Updates the vault tvl cap (the max amount of assets held by the vault).
     * @dev pass in max value of uint to effectively remove TVL cap.
     * @param newTvlCap The new tvl cap.
     */
    function updateTvlCap(uint256 newTvlCap) public onlyOwner {
        tvlCap = newTvlCap;
        emit TvlCapUpdated(tvlCap);
    }

     /**
     * @notice Helper function to remove TVL cap.
     */
    function removeTvlCap() external onlyOwner {
        updateTvlCap(type(uint256).max);
    }

    /**
     * @notice Activates or deactivates Vault mode where all Strategies go into full
     * withdrawal.
     * During Emergency Shutdown:
     * 1. No Users may deposit into the Vault (but may withdraw as usual.)
     * 2. New Strategies may not be added.
     * 3. Each Strategy must pay back their debt as quickly as reasonable to
     * minimally affect their position.
     *
     * If true, the Vault goes into Emergency Shutdown. If false, the Vault
     * goes back into Normal Operation.
     * @param active If emergencyShutdown is active or not.
     */
    function setEmergencyShutdown(bool active) external onlyOwner {
        emergencyShutdown = active;
    }

    /**
     * @notice Increases user's cumulative deposits.
     * @param amount Number of tokens being deposited.
     * @param receiver The receiver of the minted shares.
     */
    function incrementDeposits(uint256 amount, address receiver) internal {
        uint256 initial = cumulativeDeposits[receiver];
        uint256 newTotal = initial + amount;
        cumulativeDeposits[receiver] = newTotal;
        emit DepositsIncremented(receiver, amount, newTotal);
    }

    /**
     * @notice increases user's cumulative withdrawals.
     * @param amount number of tokens being withdrawn.
     * @param owner The owner of the shares withdrawn.
     */
    function incrementWithdrawals(uint256 amount, address owner) internal {
        uint256 initial = cumulativeWithdrawals[owner];
        uint256 newTotal = initial + amount;
        cumulativeWithdrawals[owner] = newTotal;
        emit WithdrawalsIncremented(owner, amount, newTotal);
    }

    /**
     * @notice Rescues random funds stuck that the strat can't handle.
     * @param token address of the asset to rescue.
     */
    function inCaseTokensGetStuck(address token) external onlyOwner {
        require(token != asset, "!asset");

        uint256 amount = IERC20Metadata(token).balanceOf(address(this));
        IERC20Metadata(token).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Overrides the default 18 decimals for the vault ERC20 to
     * match the same decimals as the underlying asset used.
     * @return decimals - the amount of decimals used by the vault ERC20.
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    /**
     * @notice Changes the locked profit degradation.
     * match the same decimals as the underlying asset used.
     * @param degradation - The rate of degradation in percent per second scaled to 1e18.
     */
    function setLockedProfitDegradation(uint256 degradation) external onlyOwner {
        require(degradation <= DEGRADATION_COEFFICIENT);
        lockedProfitDegradation = degradation;
        emit LockedProfitDegradationUpdated(degradation);
    }
}
