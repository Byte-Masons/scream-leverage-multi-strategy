async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
  const stratContract = await hre.upgrades.upgradeProxy('0x31A8616375259f7EBc4D67aAf8dEdEB6947F20e1', stratFactory, {
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
