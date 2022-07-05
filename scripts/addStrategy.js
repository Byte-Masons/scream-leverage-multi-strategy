async function main() {
  const vaultAddress = '0xeb7761d05A31769D35073f703dD3a41f3ca9bD3d';
  const Vault = await ethers.getContractFactory('ReaperVaultV2');
  const vault = Vault.attach(vaultAddress);

  const strategyAddress = '0x824CcC6e02Ad721197D8A50B3a371bF2ba6E4405';
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
