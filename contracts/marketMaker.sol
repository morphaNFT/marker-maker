// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ConsiderationItem,
    OrderParameters,
    AdvancedOrder,
    CriteriaResolver,
    FulfillmentComponent
} from "./lib/ConsiderationStructs.sol";

import {
    SeaportInterface
} from "./lib/SeaportInterface.sol";

contract MarketMaker is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public deductionAccount;
    SeaportInterface public seaportContract;
    address public conduitAddress;

    // 用户存入主链币记录
    mapping(address => uint256) public userBalances;
    // 用户存入的Token余额记录
    mapping(address => mapping(address => uint256)) public userTokenBalances;
    // 平台可取主链币
    uint256 public totalDeductedETH;
    // 平台可取Token
    mapping(address => uint256) public totalDeductedTokens;

    // 记录某个token是否已经被approve给合约B
    mapping(address => bool) private approvedTokens;

    // 事件记录
    event Deposit(address indexed user, uint256 amount, address token);
    event Deduction(address indexed user, uint256 amount, address token);
    event UserRefunded(address indexed user, uint256 amount, address token);
    event ContractWithdrawal(address indexed account, uint256 amount, address token);

    constructor(address _seaport, address _conduitAddress) Ownable(msg.sender) {
        deductionAccount = msg.sender;
        require(_seaport != address(0), "Seaport address cannot be empty" );
        require(_conduitAddress != address(0), "conduit address cannot be empty" );
        seaportContract = SeaportInterface(_seaport);
        conduitAddress = _conduitAddress;
    }

    // 用户存入ETH
    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        userBalances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value, address(0));
    }

    // 用户存入Token
    function depositToken(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Deposit amount must be greater than 0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        userTokenBalances[msg.sender][token] += amount;

        // 检查token是否已经授权
        if (!approvedTokens[token]) {
            IERC20(token).forceApprove(conduitAddress, type(uint256).max);
            approvedTokens[token] = true;
        }

        emit Deposit(msg.sender, amount, token);
    }

    // 返还用户所有的主链币，只能由deductionAccount操作
    function refundUser(address user) external nonReentrant {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 balance = userBalances[user];
        require(balance > 0, "No balance to refund");
        userBalances[user] = 0;
        payable(user).transfer(balance);

        emit UserRefunded(user, balance, address(0));
    }

    // 返还用户所有的Token，只能由deductionAccount操作
    function refundUserTokens(address user, address token) external nonReentrant {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 tokenBalance = userTokenBalances[user][token];
        require(tokenBalance > 0, "No token balance to refund");
        userTokenBalances[user][token] = 0;
        IERC20(token).safeTransfer(user, tokenBalance);

        emit UserRefunded(user, tokenBalance, token);
    }


    // 平台扣除GAS费资金（主链币）【如果使用token作为交易币种，用户需要同时存入ETH用户GAS费扣除】
    function deduct(address user, uint256 amount) external nonReentrant {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        require(userBalances[user] >= amount, "Insufficient balance");
        require(amount > 0, "Deduct amount must be greater than 0");
        userBalances[user] -= amount;
        totalDeductedETH += amount;

        emit Deduction(user, amount, address(0));
    }

    // 修改扣除资金操作账户
    function setDeductionAccount(address newDeductionAccount) external onlyOwner {
        require(newDeductionAccount != address(0), "Invalid deduction account");
        deductionAccount = newDeductionAccount;
    }

    // 提取GAS费主链币（ETH）
    function withdrawFromContract(uint256 amount) external nonReentrant {
        require(msg.sender == deductionAccount, "Only withdraw account can call this function");
        require(amount <= totalDeductedETH, "Amount exceeds deducted ETH");
        require(address(this).balance >= amount, "Insufficient contract balance");
        totalDeductedETH -= amount;
        payable(msg.sender).transfer(amount);

        emit ContractWithdrawal(msg.sender, amount, address(0));
    }

    // 接收ETH
    receive() external payable {
        userBalances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value, address(0));
    }

    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    )
    external nonReentrant
    {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");

        (uint256 totalAmount, address token) = _calculateTotalAmountAndGetToken(advancedOrders);
        if (totalAmount > 0) {
            // 先扣款
            if (token == address(0)) {
                require(userBalances[recipient] >= totalAmount, "Insufficient balance");
                userBalances[recipient] -= totalAmount;
            } else {
                require(userTokenBalances[recipient][token] >= totalAmount, "Insufficient token balance");
                userTokenBalances[recipient][token] -= totalAmount;
            }

            uint256 amount = totalAmount;
            if (token != address(0)) {
                amount = 0;
            }

            // nft交易
            seaportContract.fulfillAvailableAdvancedOrders{value: amount}(
                advancedOrders,
                criteriaResolvers,
                offerFulfillments,
                considerationFulfillments,
                fulfillerConduitKey,
                recipient,
                maximumFulfilled
            );
        }
    }

    function _calculateTotalAmountAndGetToken(AdvancedOrder[] memory advancedOrders) internal pure returns (uint256 totalStartAmount, address token) {
        totalStartAmount = 0;
        token = address(0);
        for (uint i = 0; i < advancedOrders.length; i++) {
            OrderParameters memory params = advancedOrders[i].parameters;

            for (uint j = 0; j < params.consideration.length; j++) {
                ConsiderationItem memory item = params.consideration[j];

                totalStartAmount += item.startAmount;

                if (i == 0 && j == 0) {
                    token = item.token;
                }
            }
        }
    }


}
