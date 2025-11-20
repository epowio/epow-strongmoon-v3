require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { ETHW_RPC_URL, PRIVATE_KEY } = process.env;

module.exports = {
  solidity: {
    compilers: [
      { version: "0.4.19" },
      {
        version: "0.7.6",
        settings: { optimizer: { enabled: true, runs: 999999 } }
      },
      {
        version: "0.8.19",
        settings: { optimizer: { enabled: true, runs: 500 } }
      },
      {
        version: "0.8.20",
        settings: {
          optimizer: { enabled: true, runs: 500 },
          viaIR: true
        }
      }
    ],
    overrides: {
      "@uniswap/v3-core/contracts/**/*.sol": {
        version: "0.7.6",
        settings: { optimizer: { enabled: true, runs: 999999 } }
      },
      "@uniswap/v3-periphery/contracts/**/*.sol": {
        version: "0.7.6",
        settings: { optimizer: { enabled: true, runs: 999999 } }
      }
    }
  },
  networks: {
    hardhat: { chainId: 1337 },
    localhost: { url: "http://127.0.0.1:8549", chainId: 1337 },
    ethw: {
      url: ETHW_RPC_URL || "",
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
      chainId: 10001
    }
  }
};
