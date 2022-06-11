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

import "hardhat/console.sol";

/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
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

    mapping(address => StrategyParams) public strategies;

    // Ordering that `withdraw` uses to determine which strategies to pull funds from
    address[] public withdrawalQueue;

    uint256 public constant PERCENT_DIVISOR = 10000;
    uint256 public tvlCap;

    uint256 totalAllocBPS; // Sum of allocBPS across all strategies (in BPS, <= 10k)
    uint256 totalAllocated; // Amount of tokens that have been allocated to all strategies
    uint256 lastReport; // block.timestamp of last report from any strategy

    uint256 public constructionTime;
    bool public emergencyShutdown;

    // The asset the vault accepts and looks to maximize.
    address public immutable asset;

    // Max slippage(loss) allowed when withdrawing, in BPS (0.01%)
    uint256 withdrawMaxLoss = 1;

    /**
     * + WEBSITE DISCLAIMER +
     * While we have taken precautionary measures to protect our users,
     * it is imperative that you read, understand and agree to the disclaimer below:
     *
     * Using our platform may involve financial risk of loss.
     * Never invest more than what you can afford to lose.
     * Never invest in a Reaper Vault with tokens you don't trust.
     * Never invest in a Reaper Vault with tokens whose rules for minting you don’t agree with.
     * Ensure the accuracy of the contracts for the tokens in the Reaper Vault.
     * Ensure the accuracy of the contracts for the Reaper Vault and Strategy you are depositing in.
     * Check our documentation regularly for additional disclaimers and security assessments.
     * ...and of course: DO YOUR OWN RESEARCH!!!
     *
     * By accepting these terms, you agree that Byte Masons, Fantom.Farm, or any parties
     * affiliated with the deployment and management of these vaults or their attached strategies
     * are not liable for any financial losses you might incur as a direct or indirect
     * result of investing in any of the pools on the platform.
     */
    mapping(address => bool) public hasReadAndAcceptedTerms;

    /**
     * @dev simple mappings used to determine PnL denominated in LP tokens,
     * as well as keep a generalized history of a user's protocol usage.
     */
    mapping(address => uint256) public cumulativeDeposits;
    mapping(address => uint256) public cumulativeWithdrawals;

    event TermsAccepted(address user);
    event TvlCapUpdated(uint256 newTvlCap);

    event DepositsIncremented(address user, uint256 amount, uint256 total);
    event WithdrawalsIncremented(address user, uint256 amount, uint256 total);

    /**
     * @dev Initializes the vault's own 'RF' asset.
     * This asset is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _asset the asset to maximize.
     * @param _name the name of the vault asset.
     * @param _symbol the symbol of the vault asset.
     * @param _tvlCap initial deposit cap for scaling TVL safely
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
    }

    function addStrategy(address _strategy, uint256 _allocBPS) external onlyOwner {
        require(!emergencyShutdown);
        require(_strategy != address(0));
        require(strategies[_strategy].activation == 0);
        require(address(this) == IStrategy(_strategy).vault());
        require(asset == IStrategy(_strategy).want());
        require(_allocBPS + totalAllocBPS <= PERCENT_DIVISOR);

        strategies[_strategy] = StrategyParams({
            activation: block.timestamp,
            allocBPS: _allocBPS,
            allocated: 0,
            gains: 0,
            losses: 0,
            lastReport: block.timestamp
        });

        totalAllocBPS += _allocBPS;
        withdrawalQueue.push(_strategy);
    }

    function updateStrategyAllocBPS(address _strategy, uint256 _allocBPS) external onlyOwner {
        require(strategies[_strategy].activation != 0);
        totalAllocBPS -= strategies[_strategy].allocBPS;
        strategies[_strategy].allocBPS = _allocBPS;
        totalAllocBPS += _allocBPS;
        require(totalAllocBPS <= PERCENT_DIVISOR);
    }

    function revokeStrategy(address _strategy) external {
        require(msg.sender == owner() || msg.sender == _strategy);
        if (strategies[_strategy].allocBPS == 0) {
            return;
        }

        totalAllocBPS -= strategies[_strategy].allocBPS;
        strategies[_strategy].allocBPS = 0;
    }

    /**
     * @notice Called by a strategy to determine the amount of capital that the vault is
     * able to provide it. A positive amount means that vault has excess capital to provide
     * the strategy, while a negative amount means that the strategy has a balance owing to
     * the vault.
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

    // Updates the withdrawalQueue to match the addresses and order specified.
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
     * @dev Gives user access to the client
     * @notice this does not affect vault permissions, and is read from client-side
     */
    function agreeToTerms() public returns (bool) {
        require(!hasReadAndAcceptedTerms[msg.sender], "you have already accepted the terms");
        hasReadAndAcceptedTerms[msg.sender] = true;
        emit TermsAccepted(msg.sender);
        return true;
    }

    /**
     * @dev It calculates the total underlying value of {asset} held by the system.
     * It takes into account the vault contract balance, and the balance deployed across
     * all the strategies.
     */
    function totalAssets() public view returns (uint256) {
        return IERC20Metadata(asset).balanceOf(address(this)) + totalAllocated;
    }

    /**
     * @notice The amount of shares that the Vault would exchange for the amount of assets provided,
     * in an ideal scenario where all the conditions are met.
     * @param assets The amount of underlying assets to convert to shares
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
     * @param shares The amount of shares to convert to underlying assets
     */
    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) return 0;
        return shares * totalAssets() / _totalSupply;
    }

    /**
     * @notice Maximum amount of the underlying asset that can be deposited into the Vault for the receiver, 
     * through a deposit call.
     * @param receiver The depositor, unused in this case but here as part of the ERC4626 spec.
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
     * @param assets The amount of assets to deposit
     */
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    /**
     * @dev A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        deposit(IERC20Metadata(asset).balanceOf(msg.sender), msg.sender);
    }

    /**
     * @dev The entrypoint of funds into the system. People deposit with this function
     * into the vault.
     * @notice the _before and _after variables are used to account properly for
     * 'burn-on-transaction' tokens.
     */
    function deposit(uint256 assets, address receiver) public nonReentrant returns (uint256 shares) {
        require(!emergencyShutdown);
        require(assets != 0, "please provide amount");
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");

        uint256 _before = IERC20Metadata(asset).balanceOf(address(this));
        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);
        uint256 _after = IERC20Metadata(asset).balanceOf(address(this));
        assets = _after - _before;
        if (totalSupply() == 0) {
            shares = assets;
        } else {
            shares = (assets * totalSupply()) / _pool;
        }
        _mint(receiver, shares);
        incrementDeposits(assets);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Maximum amount of shares that can be minted from the Vault for the receiver, through a mint call.
     * @param receiver The minter, unused in this case but here as part of the ERC4626 spec.
     */
    function maxMint(address receiver) public view virtual returns (uint256) {
        return convertToShares(maxDeposit(address(0)));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their mint at the current block, 
     * given current on-chain conditions.
     * @param shares The amount of shares to mint.
     */
    function previewMint(uint256 shares) external view returns (uint256) {
        uint256 assets = convertToAssets(shares);
        if (assets == 0 && totalAssets() == 0) return shares;
        return assets;
    }

    /**
     * @notice Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
     * @param shares The amount of shares to mint.
     * @param receiver The receiver of the minted shares.
     */
    function mint(uint256 shares, address receiver) public returns (uint256) {
        require(!emergencyShutdown);
        require(shares != 0, "please provide amount");
        uint256 assets = convertToAssets(shares);
        uint256 _pool = totalAssets();
        require(_pool + assets <= tvlCap, "vault is full!");

        if (totalAssets() == 0) assets = shares;

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);
        incrementDeposits(assets);
        emit Deposit(msg.sender, receiver, assets, shares);

        return assets;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    /**
     * @notice Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block,
     * given current on-chain conditions.
     * @param assets The amount of assets to withdraw.
     */
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        uint256 shares = convertToShares(assets);
        if (totalSupply() == 0) return 0;
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(assets > 0, "please provide amount");
        shares = convertToShares(assets);
        _withdraw(assets, shares, receiver, owner);
        return shares;
    }

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
        incrementWithdrawals(assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf(owner);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     */
    function redeemAll() external {
        redeem(balanceOf(msg.sender), msg.sender, msg.sender);
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategies and pay up the asset holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function redeem(uint256 shares, address receiver, address owner) public nonReentrant returns (uint256 assets) {
        require(shares > 0, "please provide amount");
        assets = (totalAssets() * shares) / totalSupply();
        return _withdraw(assets, shares, receiver, owner);
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() public view returns (uint256) {
        return totalSupply() == 0 ? 10**decimals() : totalAssets() * 10**decimals() / totalSupply();
    }

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

    function report(int256 _roi, uint256 _repayment) external returns (uint256) {
        address stratAddr = msg.sender;
        require(strategies[stratAddr].activation != 0);

        if (_roi < 0) {
            _reportLoss(stratAddr, uint256(-_roi));
        } else {
            strategies[stratAddr].gains += uint256(_roi);
        }

        int256 available = availableCapital();
        uint256 debt = 0;
        uint256 credit = 0;
        if (available < 0) {
            debt = uint256(-available);
            uint256 repayment = Math.min(debt, _repayment);

            if (repayment != 0) {
                strategies[stratAddr].allocated -= repayment;
                totalAllocated -= repayment;
                debt -= repayment;
            }
        } else {
            credit = uint256(available);
            strategies[stratAddr].allocated += credit;
            totalAllocated += credit;
        }

        uint256 freeWantInStrat = _repayment;
        if (_roi > 0) {
            freeWantInStrat += uint256(_roi);
        }

        if (credit > freeWantInStrat) {
            IERC20Metadata(asset).safeTransfer(stratAddr, credit - freeWantInStrat);
        } else if (credit < freeWantInStrat) {
            IERC20Metadata(asset).safeTransferFrom(stratAddr, address(this), freeWantInStrat - credit);
        }

        strategies[stratAddr].lastReport = block.timestamp;
        lastReport = block.timestamp;

        if (strategies[stratAddr].allocBPS == 0 || emergencyShutdown) {
            return IStrategy(stratAddr).balanceOf();
        }

        return debt;
    }

    function updateWithdrawMaxLoss(uint256 _withdrawMaxLoss) external onlyOwner {
        require(_withdrawMaxLoss <= PERCENT_DIVISOR);
        withdrawMaxLoss = _withdrawMaxLoss;
    }

    /**
     * @dev pass in max value of uint to effectively remove TVL cap
     */
    function updateTvlCap(uint256 _newTvlCap) public onlyOwner {
        tvlCap = _newTvlCap;
        emit TvlCapUpdated(tvlCap);
    }

    /**
     * @dev helper function to remove TVL cap
     */
    function removeTvlCap() external onlyOwner {
        updateTvlCap(type(uint256).max);
    }

    /**
     * Activates or deactivates Vault mode where all Strategies go into full
     * withdrawal.
     * During Emergency Shutdown:
     * 1. No Users may deposit into the Vault (but may withdraw as usual.)
     * 2. New Strategies may not be added.
     * 3. Each Strategy must pay back their debt as quickly as reasonable to
     * minimally affect their position.
     *
     * If true, the Vault goes into Emergency Shutdown. If false, the Vault
     * goes back into Normal Operation.
     */
    function setEmergencyShutdown(bool _active) external onlyOwner {
        emergencyShutdown = _active;
    }

    /*
     * @dev functions to increase user's cumulative deposits and withdrawals
     * @param _amount number of LP tokens being deposited/withdrawn
     */
    function incrementDeposits(uint256 _amount) internal returns (bool) {
        uint256 initial = cumulativeDeposits[tx.origin];
        uint256 newTotal = initial + _amount;
        cumulativeDeposits[tx.origin] = newTotal;
        emit DepositsIncremented(tx.origin, _amount, newTotal);
        return true;
    }

    function incrementWithdrawals(uint256 _amount) internal returns (bool) {
        uint256 initial = cumulativeWithdrawals[tx.origin];
        uint256 newTotal = initial + _amount;
        cumulativeWithdrawals[tx.origin] = newTotal;
        emit WithdrawalsIncremented(tx.origin, _amount, newTotal);
        return true;
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param _token address of the asset to rescue.
     */
    function inCaseTokensGetStuck(address _token) external onlyOwner {
        require(_token != asset, "!asset");

        uint256 amount = IERC20Metadata(_token).balanceOf(address(this));
        IERC20Metadata(_token).safeTransfer(msg.sender, amount);
    }

    /**
     * @dev Overrides the default 18 decimals for the vault ERC20 to
     * match the same decimals as the underlying asset used
     */
    function decimals() public view override returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }
}
