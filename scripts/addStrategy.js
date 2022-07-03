async function main() {
  const vaultAddress = '0x58C60B6dF933Ff5615890dDdDCdD280bad53f1C1';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0xaaBFBC79DaaA5e9B882EE10D4acCB96c72e366A8';
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
