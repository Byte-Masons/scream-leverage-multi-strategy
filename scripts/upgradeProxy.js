async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
  const stratContract = await hre.upgrades.upgradeProxy('0xaaBFBC79DaaA5e9B882EE10D4acCB96c72e366A8', stratFactory, {
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
