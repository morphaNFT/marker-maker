## Project Structure Introduction
### contract
- contracts/marketMaker.sol  ## NFT Market Making Wallet Contract
### script
- scripts/deploy.js   ## Contract deployment script

## Prepare the environment
Install Node.js

## Install dependencies
```shell
npm install
```
## Private key configuration
Configure the private key in the config. js file
```json
{
  "common": {
    "privateKey": ""
  }
}
```

## Configure blockchain address
`hardhat.config.js` Write the network address to be deployed in the 'url' section of the configuration file
```js
networks: {
    morph: {
      url: `https://rpc-quicknode-holesky.morphl2.io`,
      accounts: [`0x${config.common.privateKey}`]
    }
}
```

## Deploy contract
```shell
 npx hardhat run ./scripts/deploy.js --network morph
```