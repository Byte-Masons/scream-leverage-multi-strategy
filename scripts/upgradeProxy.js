async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
  const stratContract = await hre.upgrades.upgradeProxy('0x824CcC6e02Ad721197D8A50B3a371bF2ba6E4405', stratFactory, {
    timeout: 0,
  });
  console.log('Strategy upgraded!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
