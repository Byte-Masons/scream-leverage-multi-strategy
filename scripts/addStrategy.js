async function main() {
  const vaultAddress = '0xcdA5deA176F2dF95082f4daDb96255Bdb2bc7C7D';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x31A8616375259f7EBc4D67aAf8dEdEB6947F20e1';
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
