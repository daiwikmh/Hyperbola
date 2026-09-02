// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

contract QuoteRegistry {
    struct Quote {
        uint256 price;
        uint256 expiry;
    }

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint256 public constant MAX_ACTIVE_QUOTERS = 32;
    uint256 public constant MAX_QUOTE_DURATION = 5 minutes;

    mapping(address => uint256) public stakeOf;
    mapping(PoolId => mapping(address => Quote)) public quoteOf;
    mapping(PoolId => address[]) private _quoters;
    mapping(PoolId => mapping(address => uint256)) private _quoterIndex;

    event Staked(address indexed arbitrageur, uint256 amount);
    event Unstaked(address indexed arbitrageur, uint256 amount);
    event QuotePosted(PoolId indexed poolId, address indexed arbitrageur, uint256 price, uint256 expiry);
    event QuoteWithdrawn(PoolId indexed poolId, address indexed arbitrageur);

    error InsufficientStake();
    error TooManyQuoters();
    error InvalidExpiry();
    error NotAQuoter();
    error InsufficientBalance();
    error TransferFailed();
    error InvalidPrice();

    function stake() external payable {
        stakeOf[msg.sender] += msg.value;
        emit Staked(msg.sender, msg.value);
    }

    function unstake(uint256 amount) external {
        if (stakeOf[msg.sender] < amount) revert InsufficientBalance();
        stakeOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    function postQuote(PoolId poolId, uint256 price, uint256 expiry) external {
        if (stakeOf[msg.sender] < MIN_STAKE) revert InsufficientStake();
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_QUOTE_DURATION) revert InvalidExpiry();

        if (_quoterIndex[poolId][msg.sender] == 0) {
            if (_quoters[poolId].length >= MAX_ACTIVE_QUOTERS) revert TooManyQuoters();
            _quoters[poolId].push(msg.sender);
            _quoterIndex[poolId][msg.sender] = _quoters[poolId].length;
        }
        quoteOf[poolId][msg.sender] = Quote(price, expiry);
        emit QuotePosted(poolId, msg.sender, price, expiry);
    }

    function withdrawQuote(PoolId poolId) external {
        _removeQuoter(poolId, msg.sender);
    }

    function _removeQuoter(PoolId poolId, address who) internal {
        uint256 idx = _quoterIndex[poolId][who];
        if (idx == 0) revert NotAQuoter();
        uint256 lastIdx = _quoters[poolId].length;
        address lastQuoter = _quoters[poolId][lastIdx - 1];
        _quoters[poolId][idx - 1] = lastQuoter;
        _quoterIndex[poolId][lastQuoter] = idx;
        _quoters[poolId].pop();
        delete _quoterIndex[poolId][who];
        delete quoteOf[poolId][who];
        emit QuoteWithdrawn(poolId, who);
    }

    function activeQuoters(PoolId poolId) external view returns (address[] memory) {
        return _quoters[poolId];
    }

    function isLive(PoolId poolId, address who) public view returns (bool) {
        Quote memory q = quoteOf[poolId][who];
        return q.expiry > block.timestamp && stakeOf[who] >= MIN_STAKE;
    }

    function bestForXForY(PoolId poolId)
        external
        view
        returns (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice)
    {
        address[] memory ps = _quoters[poolId];
        for (uint256 i = 0; i < ps.length; i++) {
            if (!isLive(poolId, ps[i])) continue;
            uint256 p = quoteOf[poolId][ps[i]].price;
            if (!found || p > winnerPrice) {
                secondPrice = found ? winnerPrice : 0;
                secondQuoter = found ? winner : address(0);
                winnerPrice = p;
                winner = ps[i];
                found = true;
            } else if (p > secondPrice) {
                secondPrice = p;
                secondQuoter = ps[i];
            }
        }
    }

    function bestForYForX(PoolId poolId)
        external
        view
        returns (bool found, address winner, uint256 winnerPrice, address secondQuoter, uint256 secondPrice)
    {
        address[] memory ps = _quoters[poolId];
        secondPrice = type(uint256).max;
        for (uint256 i = 0; i < ps.length; i++) {
            if (!isLive(poolId, ps[i])) continue;
            uint256 p = quoteOf[poolId][ps[i]].price;
            if (!found || p < winnerPrice) {
                secondPrice = found ? winnerPrice : type(uint256).max;
                secondQuoter = found ? winner : address(0);
                winnerPrice = p;
                winner = ps[i];
                found = true;
            } else if (p < secondPrice) {
                secondPrice = p;
                secondQuoter = ps[i];
            }
        }
        if (secondPrice == type(uint256).max) secondPrice = 0;
    }
}
