const hre = require('hardhat');
const chai = require('chai');
const {solidity} = require('ethereum-waffle');
chai.use(solidity);
const {expect} = chai;

const moveTimeForward = async (seconds) => {
  await network.provider.send('evm_increaseTime', [seconds]);
  await network.provider.send('evm_mine');
};

// use with small values in case harvest is block-dependent instead of time-dependent
const moveBlocksForward = async (blocks) => {
  for (let i = 0; i < blocks; i++) {
    await network.provider.send('evm_increaseTime', [1]);
    await network.provider.send('evm_mine');
  }
};

const toWantUnit = (num, isUSDC = false) => {
  if (isUSDC) {
    return ethers.BigNumber.from(num * 10 ** 8);
  }
  return ethers.utils.parseEther(num);
};

describe('Vaults', function () {
  let Vault;
  let vault;

  let Strategy;
  let strategy;

  let Want;
  let want;
  let wftm;

  const treasuryAddr = '0x0e7c5313E9BB80b654734d9b7aB1FB01468deE3b';
  const paymentSplitterAddress = '0x63cbd4134c2253041F370472c130e92daE4Ff174';

  const superAdminAddress = '0x04C710a1E8a738CDf7cAD3a52Ba77A784C35d8CE';
  const adminAddress = '0x539eF36C804e4D735d8cAb69e8e441c12d4B88E0';
  const guardianAddress = '0xf20E25f2AB644C8ecBFc992a6829478a85A98F2c';
  const wftmAddress = '0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83';
  const wantAddress = wftmAddress;
  const scWant = '0xb681F4928658a8d54bd4773F5B5DEAb35d63c3CF';

  const wantHolderAddr = '0x431e81e5dfb5a24541b5ff8762bdef3f32f96354';
  const strategistAddr = '0x1A20D7A31e5B3Bc5f02c8A146EF6f394502a10c4';

  let owner;
  let wantHolder;
  let strategist;
  let guardian;
  let admin;
  let superAdmin;
  let unassignedRole;

  beforeEach(async function () {
    //reset network
    await network.provider.request({
      method: 'hardhat_reset',
      params: [
        {
          forking: {
            jsonRpcUrl: 'https://rpcapi-tracing.fantom.network/',
            blockNumber: 39545675,
          },
        },
      ],
    });

    //get signers
    [owner, unassignedRole] = await ethers.getSigners();
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [wantHolderAddr],
    });
    wantHolder = await ethers.provider.getSigner(wantHolderAddr);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [strategistAddr],
    });
    strategist = await ethers.provider.getSigner(strategistAddr);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [adminAddress],
    });
    admin = await ethers.provider.getSigner(adminAddress);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [superAdminAddress],
    });
    superAdmin = await ethers.provider.getSigner(superAdminAddress);
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [guardianAddress],
    });
    guardian = await ethers.provider.getSigner(guardianAddress);

    //get artifacts
    Vault = await ethers.getContractFactory('ReaperVaultV2');
    Strategy = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
    Want = await ethers.getContractFactory('@openzeppelin/contracts/token/ERC20/ERC20.sol:ERC20');

    //deploy contracts
    vault = await Vault.deploy(wantAddress, 'TOMB-MAI Tomb Crypt', 'rf-TOMB-MAI', ethers.constants.MaxUint256);

    strategy = await hre.upgrades.deployProxy(
      Strategy,
      [
        vault.address,
        [treasuryAddr, paymentSplitterAddress],
        [strategistAddr],
        [superAdminAddress, adminAddress, guardianAddress],
        scWant,
      ],
      {kind: 'uups'},
    );
    await strategy.deployed();
    await vault.addStrategy(strategy.address, 9000);
    want = await Want.attach(wantAddress);
    wftm = await Want.attach(wftmAddress);

    //approving LP token and vault share spend
    await want.connect(wantHolder).approve(vault.address, ethers.constants.MaxUint256);
  });

  xdescribe('Deploying the vault and strategy', function () {
    it('should initiate vault with a 0 balance', async function () {
      const totalBalance = await vault.totalAssets();
      const pricePerFullShare = await vault.getPricePerFullShare();
      expect(totalBalance).to.equal(0);
      expect(pricePerFullShare).to.equal(ethers.utils.parseEther('1'));
    });
  });

  xdescribe('Access control tests', function () {
    it('unassignedRole has no privileges', async function () {
      await expect(strategy.connect(unassignedRole).updateHarvestLogCadence(10)).to.be.reverted;

      await expect(strategy.connect(unassignedRole).setEmergencyExit()).to.be.reverted;
    });

    it('strategist has right privileges', async function () {
      await expect(strategy.connect(strategist).updateHarvestLogCadence(10)).to.not.be.reverted;

      await expect(strategy.connect(strategist).setEmergencyExit()).to.be.reverted;
    });

    it('guardian has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: guardianAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(guardian).updateHarvestLogCadence(10)).to.not.be.reverted;

      await expect(strategy.connect(guardian).setEmergencyExit()).to.not.be.reverted;
    });

    it('admin has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: adminAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(admin).updateHarvestLogCadence(10)).to.not.be.reverted;

      await expect(strategy.connect(admin).setEmergencyExit()).to.not.be.reverted;
    });

    it('super-admin/owner has right privileges', async function () {
      const tx = await strategist.sendTransaction({
        to: superAdminAddress,
        value: ethers.utils.parseEther('1.0'),
      });
      await tx.wait();

      await expect(strategy.connect(superAdmin).updateHarvestLogCadence(10)).to.not.be.reverted;

      await expect(strategy.connect(superAdmin).setEmergencyExit()).to.not.be.reverted;
    });
  });

  describe('Vault Tests', function () {
    xit('should allow deposits and account for them correctly', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const vaultBalance = await vault.totalAssets();
      const depositAmount = toWantUnit('10');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const newVaultBalance = await vault.totalAssets();
      const newUserBalance = await want.balanceOf(wantHolderAddr);
      const allowedInaccuracy = depositAmount.div(200);
      expect(depositAmount).to.be.closeTo(newVaultBalance, allowedInaccuracy);
    });

    xit('should mint user their pool share', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('10');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const ownerDepositAmount = toWantUnit('0.1');
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount, owner.address);

      const allowedImprecision = toWantUnit('0.0001');

      const userVaultBalance = await vault.balanceOf(wantHolderAddr);
      expect(userVaultBalance).to.be.closeTo(depositAmount, allowedImprecision);
      const ownerVaultBalance = await vault.balanceOf(owner.address);
      expect(ownerVaultBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);

      await vault.connect(owner).withdrawAll();
      const ownerWantBalance = await want.balanceOf(owner.address);
      expect(ownerWantBalance).to.be.closeTo(ownerDepositAmount, allowedImprecision);
      const afterOwnerVaultBalance = await vault.balanceOf(owner.address);
      expect(afterOwnerVaultBalance).to.equal(0);
    });

    xit('should allow withdrawals', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('100');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      await vault.connect(wantHolder).withdrawAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance;
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      console.log(`expectedBalance: ${expectedBalance}`);
      console.log(`userBalanceAfterWithdraw: ${userBalanceAfterWithdraw}`);
      console.log(`expectedBalance.sub(userBalanceAfterWithdraw): ${expectedBalance.sub(userBalanceAfterWithdraw)}`);
      console.log(`smallDifference: ${smallDifference}`);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    xit('should allow small withdrawal', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.0000001');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      const ownerDepositAmount = toWantUnit('0.1');
      await want.connect(wantHolder).transfer(owner.address, ownerDepositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      await vault.connect(owner).deposit(ownerDepositAmount, owner.address);

      await vault.connect(wantHolder).withdrawAll();
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance.sub(ownerDepositAmount);
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      console.log(`expectedBalance: ${expectedBalance}`);
      console.log(`userBalanceAfterWithdraw: ${userBalanceAfterWithdraw}`);
      console.log(`expectedBalance.sub(userBalanceAfterWithdraw): ${expectedBalance.sub(userBalanceAfterWithdraw)}`);
      console.log(`smallDifference: ${smallDifference}`);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    xit('should handle small deposit + withdraw', async function () {
      const userBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = toWantUnit('0.000001');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();

      await vault.connect(wantHolder).withdraw(depositAmount);
      const newUserVaultBalance = await vault.balanceOf(wantHolderAddr);
      const userBalanceAfterWithdraw = await want.balanceOf(wantHolderAddr);

      const expectedBalance = userBalance;
      const smallDifference = depositAmount.div(200);
      const isSmallBalanceDifference = expectedBalance.sub(userBalanceAfterWithdraw).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    xit('should be able to convert assets in to amount of shares', async function () {
      const depositAmount = toWantUnit('100');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      let totalAssets = await vault.totalAssets();
      console.log(`totalAssets: ${totalAssets}`);
      // Modify the price per share to not be 1 to 1
      await want.connect(wantHolder).transfer(vault.address, toWantUnit('1337'));
      totalAssets = await vault.totalAssets();
      console.log(`totalAssets: ${totalAssets}`);

      await want.connect(wantHolder).transfer(owner.address, depositAmount);
      await want.connect(owner).approve(vault.address, ethers.constants.MaxUint256);
      const shares = await vault.connect(owner).convertToShares(depositAmount);
      await vault.connect(owner).deposit(depositAmount, owner.address);
      console.log(`shares: ${shares}`);

      const vaultBalance = await vault.balanceOf(owner.address);
      console.log(`vaultBalance: ${vaultBalance}`);
      expect(shares).to.equal(vaultBalance);
    });

    xit('should be able to convert shares in to amount of assets', async function () {
      const shareAmount = toWantUnit('100');
      let assets = await vault.convertToAssets(shareAmount);
      expect(assets).to.equal(0);
      console.log(`assets: ${assets}`);

      const depositAmount = toWantUnit('1337');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      await want.connect(wantHolder).transfer(vault.address, depositAmount);

      assets = await vault.convertToAssets(shareAmount);
      console.log(`assets: ${assets}`);
      expect(assets).to.equal(shareAmount.mul(2));
    });

    xit('maxDeposit returns the maximum amount that can be deposited', async function () {
      let tvlCap = toWantUnit('50');
      await vault.updateTvlCap(tvlCap);
      let maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(tvlCap);

      const depositAmount = toWantUnit('25');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(tvlCap.sub(depositAmount));

      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(0);

      tvlCap = toWantUnit('10');
      await vault.updateTvlCap(tvlCap);
      maxDeposit = await vault.maxDeposit(wantHolderAddr);
      expect(maxDeposit).to.equal(0);
    });

    xit('can previewDeposit', async function () {
      let depositAmount = toWantUnit('137');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);

      depositAmount = toWantUnit('44');
      let depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      let vaultBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      let vaultBalanceAfter = await vault.balanceOf(wantHolderAddr);
      let balanceIncrease = vaultBalanceAfter.sub(vaultBalance);
      expect(depositPreview).to.equal(balanceIncrease);

      await want.connect(wantHolder).transfer(vault.address, toWantUnit('11346'));

      depositAmount = toWantUnit('130');
      depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      vaultBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      vaultBalanceAfter = await vault.balanceOf(wantHolderAddr);
      balanceIncrease = vaultBalanceAfter.sub(vaultBalance);
      expect(depositPreview).to.equal(balanceIncrease);
    });

    xit('maxMint returns the max amount of shares that can be minted', async function () {
      let maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(ethers.constants.MaxUint256);

      let tvlCap = toWantUnit('50');
      await vault.updateTvlCap(tvlCap);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(tvlCap);

      let depositAmount = toWantUnit('35');
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(tvlCap.sub(depositAmount));

      // Change the price per share
      const transferAmount = toWantUnit('11346');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);
      depositAmount = toWantUnit('15');
      await vault.updateTvlCap(tvlCap.add(transferAmount).add(depositAmount));
      const depositPreview = await vault.connect(wantHolder).previewDeposit(depositAmount);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      maxMint = await vault.connect(wantHolder).maxMint(ethers.constants.AddressZero);
      expect(maxMint).to.equal(depositPreview);
    });

    xit('previewMint returns the amount of asset taken on a mint', async function () {
      let mintAmount = toWantUnit('55');
      let mintPreview = await vault.connect(wantHolder).previewMint(mintAmount);
      expect(mintPreview).to.equal(mintAmount);

      let userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintPreview));

      // Change the price per share
      const transferAmount = toWantUnit('11346');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      mintAmount = toWantUnit('13');
      mintPreview = await vault.connect(wantHolder).previewMint(mintAmount);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintPreview));
    });

    it('mint creates the correct amount of shares', async function () {
      let mintAmount = toWantUnit('55');
      let userBalance = await want.balanceOf(wantHolderAddr);
      // let shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      let shareBalanceAfterMint = await vault.balanceOf(wantHolderAddr);
      let userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      expect(userBalanceAfterMint).to.equal(userBalance.sub(mintAmount));
      expect(shareBalanceAfterMint).to.equal(mintAmount);

      // Change the price per share
      const transferAmount = toWantUnit('11346');
      await want.connect(wantHolder).transfer(vault.address, transferAmount);

      // Ensure it mints expected amount of shares with different price per share
      mintAmount = toWantUnit('11');
      let shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(mintAmount, wantHolderAddr);
      shareBalanceAfterMint = await vault.balanceOf(wantHolderAddr);
      expect(shareBalanceAfterMint).to.equal(shareBalance.add(mintAmount));

      // Ensure deposit and mint are equivalent
      const depositAmount = toWantUnit('56');
      shareBalance = await vault.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      const shareBalanceAfterDeposit = await vault.balanceOf(wantHolderAddr);
      const depositShareIncrease = shareBalanceAfterDeposit.sub(shareBalance);
      userBalance = await want.balanceOf(wantHolderAddr);
      await vault.connect(wantHolder).mint(depositShareIncrease, wantHolderAddr);
      userBalanceAfterMint = await want.balanceOf(wantHolderAddr);
      const mintedAssets = userBalance.sub(userBalanceAfterMint);
      const allowedInaccuracy = 10;
      expect(depositAmount).to.be.closeTo(mintedAssets, allowedInaccuracy);
    });
  });

  xdescribe('Strategy', function () {
    it('should be able to harvest', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'));
      await strategy.harvest();
      await moveTimeForward(3600);
      const readOnlyStrat = await strategy.connect(ethers.provider);
      const predictedCallerFee = await readOnlyStrat.callStatic.harvest();
      console.log(`predicted caller fee ${ethers.utils.formatEther(predictedCallerFee)}`);

      const wftmBalBefore = await wftm.balanceOf(owner.address);
      await strategy.harvest();
      const wftmBalAfter = await wftm.balanceOf(owner.address);
      const wftmBalDifference = wftmBalAfter.sub(wftmBalBefore);
      console.log(`actual caller fee ${ethers.utils.formatEther(wftmBalDifference)}`);
    });

    it('should provide yield', async function () {
      const timeToSkip = 3600;
      const initialUserBalance = await want.balanceOf(wantHolderAddr);
      const depositAmount = initialUserBalance.div(10);

      await vault.connect(wantHolder).deposit(depositAmount, wantHolderAddr);
      await strategy.harvest();
      const initialVaultBalance = await vault.totalAssets();

      await strategy.updateHarvestLogCadence(timeToSkip / 2);

      const numHarvests = 5;
      for (let i = 0; i < numHarvests; i++) {
        await moveTimeForward(timeToSkip);
        await strategy.harvest();
      }

      const finalVaultBalance = await vault.totalAssets();
      expect(finalVaultBalance).to.be.gt(initialVaultBalance);

      const averageAPR = await strategy.averageAPRAcrossLastNHarvests(numHarvests);
      console.log(`Average APR across ${numHarvests} harvests is ${averageAPR} basis points.`);
    });
  });

  describe('Vault<>Strat accounting', function () {
    xit('Strat gets more money when it flows in', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('500'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('50'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = ethers.utils.parseEther('450');
      let smallDifference = expectedStrategyBalance.div(1e12);
      console.log(`smallDifference ${smallDifference}`);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.connect(wantHolder).deposit(toWantUnit('500'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      console.log(`vaultBalance ${vaultBalance}`);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('100'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('900');
      smallDifference = expectedStrategyBalance.div(1e12);
      console.log(`smallDifference ${smallDifference}`);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    xit('Vault pulls funds from strat as needed', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('100'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = ethers.utils.parseEther('900');
      let smallDifference = expectedStrategyBalance.div(1e12);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.updateStrategyAllocBPS(strategy.address, 7000);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('300'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('700');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.connect(wantHolder).deposit(toWantUnit('100'), wantHolderAddr);
      await strategy.harvest();
      await moveTimeForward(3600);
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('330'));
      stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('770');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });
  });

  xdescribe('Emergency scenarios', function () {
    it('Vault should handle emergency shutdown', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'));
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('100'));
      let stratBalance = await strategy.balanceOf();
      expectedStrategyBalance = ethers.utils.parseEther('900');
      smallDifference = expectedStrategyBalance.div(1e12);
      isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.setEmergencyShutdown(true);
      await strategy.harvest();
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('1000'));
      stratBalance = await strategy.balanceOf();
      smallDifference = vaultBalance.div(1e12);
      isSmallBalanceDifference = stratBalance.lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });

    it('Strategy should handle emergency exit', async function () {
      await vault.connect(wantHolder).deposit(toWantUnit('1000'));
      await strategy.harvest();
      await moveTimeForward(3600);
      let vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.equal(ethers.utils.parseEther('100'));
      let stratBalance = await strategy.balanceOf();
      let expectedStrategyBalance = ethers.utils.parseEther('900');
      let smallDifference = expectedStrategyBalance.div(1e12);
      let isSmallBalanceDifference = expectedStrategyBalance.sub(stratBalance).lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);

      await vault.setEmergencyShutdown(true);
      await strategy.harvest();
      vaultBalance = await want.balanceOf(vault.address);
      expect(vaultBalance).to.be.gte(ethers.utils.parseEther('1000'));
      stratBalance = await strategy.balanceOf();
      smallDifference = vaultBalance.div(1e12);
      isSmallBalanceDifference = stratBalance.lt(smallDifference);
      expect(isSmallBalanceDifference).to.equal(true);
    });
  });
});
