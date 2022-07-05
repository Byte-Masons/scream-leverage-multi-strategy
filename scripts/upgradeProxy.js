async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
  const stratContract = await hre.upgrades.upgradeProxy('0xd2e77d311dDca106d64c61E8CCb258d37636dd68', stratFactory, {
    timeout: 0,
    gasPrice: 300000000000,
    gasLimit: 9000000,
  });
  console.log('Strategy upgraded!');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
