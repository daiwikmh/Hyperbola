// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

contract ArbitrageurVault {
    using CurrencyLibrary for Currency;

    address public hook;
    address public immutable owner;

    mapping(address => mapping(Currency => uint256)) public balanceOf;

    event Deposited(address indexed arbitrageur, Currency indexed currency, uint256 amount);
    event Withdrawn(address indexed arbitrageur, Currency indexed currency, uint256 amount);
    event PulledForHook(address indexed arbitrageur, Currency indexed currency, uint256 amount, address to);
    event CreditedByHook(address indexed arbitrageur, Currency indexed currency, uint256 amount);

    error HookAlreadySet();
    error NotHook();
    error NotOwner();
    error InsufficientBalance();

    constructor() {
        owner = msg.sender;
    }

    function setHook(address _hook) external {
        if (msg.sender != owner) revert NotOwner();
        if (hook != address(0)) revert HookAlreadySet();
        hook = _hook;
    }

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    function deposit(Currency currency, uint256 amount) external {
        uint256 balanceBefore = currency.balanceOfSelf();
        IERC20Minimal(Currency.unwrap(currency)).transferFrom(msg.sender, address(this), amount);
        uint256 received = currency.balanceOfSelf() - balanceBefore;
        balanceOf[msg.sender][currency] += received;
        emit Deposited(msg.sender, currency, received);
    }

    function withdraw(Currency currency, uint256 amount) external {
        if (balanceOf[msg.sender][currency] < amount) revert InsufficientBalance();
        balanceOf[msg.sender][currency] -= amount;
        currency.transfer(msg.sender, amount);
        emit Withdrawn(msg.sender, currency, amount);
    }

    function pullFor(address arbitrageur, Currency currency, uint256 amount, address to)
        external
        onlyHook
        returns (uint256 actual)
    {
        uint256 available = balanceOf[arbitrageur][currency];
        actual = amount > available ? available : amount;
        balanceOf[arbitrageur][currency] = available - actual;
        if (actual > 0) currency.transfer(to, actual);
        emit PulledForHook(arbitrageur, currency, actual, to);
    }

    function creditFor(address arbitrageur, Currency currency, uint256 amount) external onlyHook {
        balanceOf[arbitrageur][currency] += amount;
        emit CreditedByHook(arbitrageur, currency, amount);
    }
}
