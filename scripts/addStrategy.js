async function main() {
  const vaultAddress = '0x77dc33dC0278d21398cb9b16CbFf99c1B712a87A';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x2fbEDa4876341Ef0Bcb4AA9e135Bb99e41A09CC4';
  const strategyAllocation = 9900;
  await vault.addStrategy(strategyAddress, strategyAllocation);
  console.log('Strategy added!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
