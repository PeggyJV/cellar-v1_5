import { task } from "hardhat/config";
import { TaskArguments } from "hardhat/types";

import { AaveV2StablecoinCellar } from "../../src/types/AaveV2StablecoinCellar";
import { AaveV2StablecoinCellar__factory } from "../../src/types/factories/AaveV2StablecoinCellar__factory";

task("deploy:AaveV2StablecoinCellar").setAction(async function (
  args: TaskArguments,
  { ethers }
) {
  const signers = await ethers.getSigners();
  console.log("Deployer address: ", signers[0].address);
  console.log("Deployer balance: ", (await signers[0].getBalance()).toString());

  const factory = <AaveV2StablecoinCellar__factory>(
    await ethers.getContractFactory("AaveV2StablecoinCellar")
  );

  const cellar = <AaveV2StablecoinCellar>await factory.deploy(
    "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", // USDC
    "0xE592427A0AEce92De3Edee1F18E0157C05861564", // Uniswap Router
    "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F", // Sushiswap Router
    "0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9", // Aave V2 Lending Pool
    "0xd784927Ff2f95ba542BfC824c8a8a98F3495f6b5", // Aave Incentives Controller V2
    "0x69592e6f9d21989a043646fE8225da2600e5A0f7", // Cosmos Gravity Bridge
    "0x4da27a545c0c5B758a6BA100e3a049001de870f5", // stkAAVE
    "0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9" // AAVE
  );

  await cellar.deployed();

  console.log("AaveV2StablecoinCellar deployed to: ", cellar.address);
});