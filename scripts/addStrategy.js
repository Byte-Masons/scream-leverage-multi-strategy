async function main() {
  const vaultAddress = '';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '';
  const strategyAllocation = 9000;
  await vault.addStrategy(strategyAddress, strategyAllocation);
  console.log('Strategy added!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
