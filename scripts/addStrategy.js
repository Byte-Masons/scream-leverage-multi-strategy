async function main() {
  const vaultAddress = '0xDFc089438B502a20516eA3515B722FbaEb853994';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0xBAA679454CCf84a456f47b7F52d816662135f2F5';
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
