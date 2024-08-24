// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {
    AdvancedOrder,
    CriteriaResolver,
    FulfillmentComponent
} from "./ConsiderationStructs.sol";


interface SeaportInterface {
    function fulfillAvailableAdvancedOrders(
        AdvancedOrder[] memory advancedOrders,
        CriteriaResolver[] calldata criteriaResolvers,
        FulfillmentComponent[][] calldata offerFulfillments,
        FulfillmentComponent[][] calldata considerationFulfillments,
        bytes32 fulfillerConduitKey,
        address recipient,
        uint256 maximumFulfilled
    ) external payable;
}