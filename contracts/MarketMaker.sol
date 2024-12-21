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

    mapping(address => uint256) public userBalances;
    mapping(address => mapping(address => uint256)) public userTokenBalances;
    mapping(address => bool) private approvedTokens;
    mapping(address => bool) private tokenSet;
    // Storage for user-specific data
    mapping(address => UserDepositData) private userDeposits;

    struct UserDepositData {
        address collectionAddress;
        address tokenAddress;
        uint256 minPrice;
        uint256 maxPrice;
    }

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
        require(_seaport != address(0), "Seaport address cannot be empty");
        require(_conduitAddress != address(0), "Conduit address cannot be empty");
        seaportContract = SeaportInterface(_seaport);
        conduitAddress = _conduitAddress;
    }

    modifier isContractActive() {
        require(isActive, "Contract is not active");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAccount, "Only operator account can call this function");
        _;
    }

    function addOrModifyToken(address token, bool isAllowed) external onlyOperator {
        tokenSet[token] = isAllowed;
    }

    function approveToken(address token) external onlyOperator {
        require(tokenSet[token], "Token is not in the allowed set");
        IERC20(token).forceApprove(conduitAddress, type(uint256).max);
        approvedTokens[token] = true;
    }

    function deposit(
        address collectionAddress,
        uint256 minPrice,
        uint256 maxPrice,
        bytes memory signature
    ) external payable nonReentrant isContractActive {
        require(msg.value > 0, "Deposit amount must be greater than 0");
        require(
            _isValidSignature(collectionAddress, address(0), minPrice, maxPrice, signature),
            "Invalid signature"
        );
        userBalances[msg.sender] += msg.value;
        userDeposits[msg.sender] = UserDepositData({
            collectionAddress: collectionAddress,
            tokenAddress: address(0),
            minPrice: minPrice,
            maxPrice: maxPrice
        });

        emit Deposit(msg.sender, msg.value, address(0));
    }

    function depositToken(
        address token,
        uint256 amount,
        address collectionAddress,
        uint256 minPrice,
        uint256 maxPrice,
        bytes memory signature
    ) external nonReentrant isContractActive {
        require(tokenSet[token], "Token is not in the allowed set");
        require(amount > 0, "Deposit amount must be greater than 0");
        require(
            _isValidSignature(collectionAddress, token, minPrice, maxPrice, signature),
            "Invalid signature"
        );

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        userTokenBalances[msg.sender][token] += amount;

        if (!approvedTokens[token]) {
            IERC20(token).forceApprove(conduitAddress, type(uint256).max);
            approvedTokens[token] = true;
        }

        userDeposits[msg.sender] = UserDepositData({
            collectionAddress: collectionAddress,
            tokenAddress: token,
            minPrice: minPrice,
            maxPrice: maxPrice
        });

        emit Deposit(msg.sender, amount, token);
    }

    function refundUser(address user) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 balance = userBalances[user];
        require(balance > 0, "No balance to refund");
        userBalances[user] = 0;
        // Delete task information
        delete userDeposits[user];
        (bool success, ) = payable(user).call{value: balance}(new bytes(0));
        require(success, "Transfer failed to the recipient");

        emit UserRefunded(user, balance, address(0));
    }
    // todo  删掉存储的任务信息
    function refundUserTokens(address user, address token) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        uint256 tokenBalance = userTokenBalances[user][token];
        require(tokenBalance > 0, "No token balance to refund");
        userTokenBalances[user][token] = 0;
        // Delete task information
        delete userDeposits[user];
        IERC20(token).safeTransfer(user, tokenBalance);

        emit UserRefunded(user, tokenBalance, token);
    }

    // todo GAS费扣除
    function deduct(address user, uint256 amount) external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        require(userBalances[user] >= amount, "Insufficient balance");
        require(amount > 0, "Deduct amount must be greater than 0");
        userBalances[user] -= amount;
        (bool success, ) = payable(operatorAccount).call{value: amount}(new bytes(0));
        require(success, "Transfer failed to the recipient");
        emit DeductGasFee(user, operatorAccount, amount);
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
    external nonReentrant isContractActive {
        require(msg.sender == deductionAccount, "Only deduction account can call this function");
        // Validate itemType for offer and consideration
        for (uint i = 0; i < advancedOrders.length; i++) {
            OrderParameters memory params = advancedOrders[i].parameters;
            for (uint j = 0; j < params.offer.length; j++) {
                require(params.offer[j].itemType == 2 || params.offer[j].itemType == 3, "Invalid offer itemType");
            }
            for (uint j = 0; j < params.consideration.length; j++) {
                require(params.consideration[j].itemType == 0 || params.consideration[j].itemType == 1, "Invalid consideration itemType");
            }
        }

        (uint256[] orderAmount, address token, address collectionAddress) = _calculateTotalAmountsAndTokenGroupOrder(advancedOrders);
        uint256 totalAmount = 0;
        for (uint i = 0; i < orderAmount.length; i++) {
            totalAmount += orderAmount[i];
            // Check if the token address matches the collection address
            require(
                userDeposits[msg.sender].tokenAddress == token,
                "Token address mismatch"
            );
            require(
                userDeposits[msg.sender].collectionAddress == collectionAddress,
                "Collection address mismatch"
            );

            // Check if the amount is within the price range
            require(
                orderAmount[i] >= userDeposits[msg.sender].minPrice &&
                orderAmount[i] <= userDeposits[msg.sender].maxPrice,
                "Order amount out of bounds"
            );
        }
        if (totalAmount > 0) {
            if (token == address(0)) {
                require(userBalances[recipient] >= totalAmount, "Insufficient balance");
                userBalances[recipient] -= totalAmount;
            } else {
                require(userTokenBalances[recipient][token] >= totalAmount, "Insufficient token balance");
                userTokenBalances[recipient][token] -= totalAmount;
            }
            uint256 amount = token == address(0) ? totalAmount : 0;
            seaportContract.fulfillAvailableAdvancedOrders{value: amount}(
                advancedOrders,
                criteriaResolvers,
                offerFulfillments,
                considerationFulfillments,
                fulfillerConduitKey,
                recipient,
                maximumFulfilled
            );
            emit OrdersFulfilled(msg.sender, recipient, totalAmount, token, maximumFulfilled);
        }
    }

//    function _calculateTotalAmountAndGetToken(AdvancedOrder[] memory advancedOrders) internal pure returns (uint256 totalStartAmount, address token) {
//        totalStartAmount = 0;
//        token = address(0);
//        for (uint i = 0; i < advancedOrders.length; i++) {
//            OrderParameters memory params = advancedOrders[i].parameters;
//            for (uint j = 0; j < params.consideration.length; j++) {
//                ConsiderationItem memory item = params.consideration[j];
//                totalStartAmount += item.startAmount;
//                if (i == 0 && j == 0) {
//                    token = item.token;
//                } else {
//                    require(item.token == token, "Order parameter not supported");
//                }
//            }
//        }
//    }

    function _calculateTotalAmountsAndTokenGroupOrder(AdvancedOrder[] memory advancedOrders)
    internal
    pure
    returns (uint256[] memory totalStartAmounts, address expectedToken, address collectionAddress)
    {
        uint256 ordersCount = advancedOrders.length;
        totalStartAmounts = new uint256[](ordersCount);
        expectedToken = address(0);
        collectionAddress = address(0);

        for (uint i = 0; i < ordersCount; i++) {
            OrderParameters memory params = advancedOrders[i].parameters;
            uint256 orderTotalStartAmount = 0;

            for (uint j = 0; j < params.consideration.length; j++) {
                ConsiderationItem memory item = params.consideration[j];
                orderTotalStartAmount += item.startAmount;

                if (i == 0 && j == 0) {
                    expectedToken = item.token;
                } else {
                    require(item.token == expectedToken, "Order token mismatch");
                }
            }

            for (uint k = 0; k < params.offer.length; k++) {
                OfferItem memory item = params.offer[k];
                if (i == 0 && k == 0) {
                    collectionAddress = item.token;
                } else {
                    require(item.token == collectionAddress, "Order collection mismatch");
                }
            }

            totalStartAmounts[i] = orderTotalStartAmount;
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

    function _isValidSignature(
        address collectionAddress,
        address tokenAddress,
        uint256 minPrice,
        uint256 maxPrice,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                msg.sender,
                collectionAddress,
                tokenAddress,
                minPrice,
                maxPrice,
                address(this),
                block.chainid
            )
        );
        bytes32 ethSignedMessageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash)
        );
        return ethSignedMessageHash.recover(signature) == msg.sender;
    }

}
