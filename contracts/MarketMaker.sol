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
    address public operatorAccount;
    bool public isActive = true;

    // Record of user depositing main chain coins
    mapping(address => uint256) public userBalances;
    // Record of Token Balance Deposited by Users
    mapping(address => mapping(address => uint256)) public userTokenBalances;

    // Record whether a certain token has been approved
    mapping(address => bool) private approvedTokens;

    // event
    event Deposit(address indexed user, uint256 amount, address token);
    event Deduction(address indexed user, uint256 amount, address token);
    event UserRefunded(address indexed user, uint256 amount, address token);
    event ContractWithdrawal(address indexed account, uint256 amount, address token);
    event ContractStatusChanged(bool isActive);
    event OperatorAccountChanged(address indexed oldOperator, address indexed newOperator);
    event DeductionAccountChanged(address indexed oldAccount, address indexed newAccount);
    event DeductGasFee(address indexed user, address indexed operator, uint256 amount);
    event OrdersFulfilled(
        address indexed fulfiller,
        address indexed recipient,
        uint256 totalAmount,
        address token,
        uint256 maximumFulfilled
    );


    constructor(address _seaport, address _conduitAddress) Ownable(msg.sender) {
        deductionAccount = msg.sender;
        operatorAccount = msg.sender;
        require(_seaport != address(0), "Seaport address cannot be empty" );
        require(_conduitAddress != address(0), "conduit address cannot be empty" );
        seaportContract = SeaportInterface(_seaport);
        conduitAddress = _conduitAddress;
    }

    // Modifier, check if the contract is in the open state
    modifier isContractActive() {
        require(isActive, "Contract is not active");
        _;
    }

    // User deposits ETH
    function deposit() external payable nonReentrant isContractActive {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        userBalances[msg.sender] += msg.value;

        emit Deposit(msg.sender, msg.value, address(0));
    }

    // User deposits Token
    function depositToken(address token, uint256 amount) external nonReentrant isContractActive {
        require(amount > 0, "Deposit amount must be greater than 0");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        userTokenBalances[msg.sender][token] += amount;
        // Check if the token has been authorized to the NFT contract
        if (!approvedTokens[token]) {
            IERC20(token).forceApprove(conduitAddress, type(uint256).max);
            approvedTokens[token] = true;
        }

        emit Deposit(msg.sender, amount, token);
    }

    // Returning all main chain coins to the user at checkout can only be operated by DeductionAccount
    function refundUser(address user) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 balance = userBalances[user];
        require(balance > 0, "No balance to refund");
        userBalances[user] = 0;
        payable(user).transfer(balance);

        emit UserRefunded(user, balance, address(0));
    }

    // Returning all tokens to the user during checkout can only be operated by DeductionAccount
    function refundUserTokens(address user, address token) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 tokenBalance = userTokenBalances[user][token];
        require(tokenBalance > 0, "No token balance to refund");
        userTokenBalances[user][token] = 0;
        IERC20(token).safeTransfer(user, tokenBalance);

        emit UserRefunded(user, tokenBalance, token);
    }


    // Platform deducts GAS fee funds (main chain currency) [If using tokens as trading currency, users need to deposit ETH at the same time for GAS fee deduction]
    function deduct(address user, uint256 amount) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        require(userBalances[user] >= amount, "Insufficient balance");
        require(amount > 0, "Deduct amount must be greater than 0");
        userBalances[user] -= amount;
        payable(operatorAccount).transfer(amount);

        emit DeductGasFee(user, operatorAccount, amount);
    }

    // Modify the deduction fund operation account
    function setDeductionAccount(address newDeductionAccount) external onlyOwner {
        require(newDeductionAccount != address(0), "Invalid deduction account");
        emit DeductionAccountChanged(deductionAccount, newDeductionAccount);

        deductionAccount = newDeductionAccount;

    }

    // Change operational address
    function setOperatorAccount(address newOperatorAccount) external onlyOwner {
        require(newOperatorAccount != address(0), "Invalid operator account");
        emit OperatorAccountChanged(operatorAccount, newOperatorAccount);

        operatorAccount = newOperatorAccount;
    }

    // Receive ETH
    receive() external payable {
        userBalances[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value, address(0));
    }

    // Purchase NFT on behalf of others
    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    )
    external nonReentrant isContractActive
    {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");

        (uint256 totalAmount, address token) = _calculateTotalAmountAndGetToken(advancedOrders);
        if (totalAmount > 0) {
            // Deduction first
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

            // NFT trading
            seaportContract.fulfillAvailableAdvancedOrders{value: amount}(
                advancedOrders,
                criteriaResolvers,
                offerFulfillments,
                considerationFulfillments,
                fulfillerConduitKey,
                recipient,
                maximumFulfilled
            );

            emit OrdersFulfilled(
                msg.sender,
                recipient,
                totalAmount,
                token,
                maximumFulfilled
            );
        }
    }
    // Calculate the order amount
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

    // Close the contract, only the operorAccount can call it
    function deactivateContract() external {
        require(msg.sender == operatorAccount, "Only operator account can deactivate the contract");
        isActive = false;

        emit ContractStatusChanged(false);
    }

    // Open the contract, only the operorAccount can call it
    function activateContract() external {
        require(msg.sender == operatorAccount, "Only operator account can activate the contract");
        isActive = true;

        emit ContractStatusChanged(true);
    }

}
