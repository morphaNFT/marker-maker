## 项目结构简介
### 合约
- contracts/marketMaker.sol  NFT做市钱包合约
### 脚本
- scripts/deploy.js   合约部署脚本

## 准备环境
安装node.js

## 安装依赖
```shell
npm install
```
## 私钥配置
将私钥配置在config.js文件中
```json
{
  "common": {
    "privateKey": ""
  }
}
```

## 配置区块链地址
在`hardhat.config.js`配置文件中,将要部署的网络地址写在`url`这里
```js
networks: {
    morph: {
      url: `https://rpc-quicknode-holesky.morphl2.io`,
      accounts: [`0x${config.common.privateKey}`]
    }
}
```

## 部署合约
```shell
 npx hardhat run ./scripts/deploy.js --network morph
```