async function main() {
  const stratFactory = await ethers.getContractFactory('ReaperStrategyScreamLeverage');
  const stratContract = await hre.upgrades.upgradeProxy('0x2fbEDa4876341Ef0Bcb4AA9e135Bb99e41A09CC4', stratFactory, {
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
