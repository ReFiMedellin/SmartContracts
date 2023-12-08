// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.4.0/contracts/security/Pausable.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract SmartContractCELO is Pausable, Ownable, ReentrancyGuard {
    /*****************************************
     *             Custom Types              *
     *****************************************/

    struct Lending {
        uint256 amount;
        uint256 initialAmount;
        uint256 startDate;
        uint256 blockMonths;
    }

    struct Lender {
        uint256 aggreedQuota;
        Lending[] lendings;
    }

    /*****************************************
     *               Storage                 *
     *****************************************/

    uint256 internal constant INTEREST_RATE_PER_DAY = 16308;
    uint256 internal constant INTEREST_PERIOD = 24 hours;

    IERC20 internal cUSDToken;
    uint256 public totalFunds;
    uint256 public totalInterest;

    mapping(address => bool) public whitelist;
    mapping(address => uint256) public property;
    mapping(address => Lender) public lenders;

    /*****************************************
     *                Events                 *
     *****************************************/

    event WhitelistedUserAdded(address indexed user);
    event WhitelistedUserRemoved(address indexed user);
    event LoanRequested(
        address indexed borrower,
        uint256 amount,
        uint16 blockMonths
    );
    event QuotaAdjusted(address indexed lender, uint256 newQuota);
    event PaymentMade(
        address indexed borrower,
        uint256 lendingIndex,
        uint256 amountPaid,
        uint256 remainingDebt
    );
    event LoanFullyRepaid(address indexed borrower, uint256 lendingIndex);

    constructor(address _cUSDTokenAddress) {
        cUSDToken = IERC20(_cUSDTokenAddress);
    }

    /*****************************************
     *                Public                 *
     *****************************************/

    function simulateInterestAccrual(uint256 _amount, uint256 _months)
        public
        pure
        returns (uint256)
    {
        uint256 compoundedAmount = _amount;
        uint256 ratePerPeriod = INTEREST_RATE_PER_DAY;
        uint256 periods = _months * 30;

        for (uint256 i = 0; i < periods; i++) {
            compoundedAmount =
                (compoundedAmount * (10**8 + ratePerPeriod)) /
                10**8;
        }
        return compoundedAmount;
    }

    /*****************************************
     *               External                *
     *****************************************/

    function capitalize(uint256 _amount) external whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        require(
            cUSDToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        totalFunds += _amount;
        property[msg.sender] += _amount;
    }

    function payDebt(uint256 _lendingIndex, uint256 _amount)
        external
        whenNotPaused
    {
        require(_amount > 0, "Payment amount must be greater than 0");
        accrueInterest(msg.sender, _lendingIndex);
        Lender storage lender = lenders[msg.sender];
        require(
            _lendingIndex <= lender.lendings.length,
            "Invalid lending index"
        );
        Lending storage lending = lender.lendings[_lendingIndex];
        require(lending.amount > 0, "No active debt to pay");
        require(_amount <= lending.amount, "Payment exceeds the debt amount");
        lending.amount -= _amount;
        require(
            cUSDToken.transferFrom(msg.sender, address(this), _amount),
            "Transfer failed"
        );
        lender.aggreedQuota += _amount;
        emit PaymentMade(msg.sender, _lendingIndex, _amount, lending.amount);

        if (lending.amount == 0) {
            emit LoanFullyRepaid(msg.sender, _lendingIndex);

            removeLending(msg.sender, _lendingIndex);
        }
    }

    function getTotalFunds(address _funder) external view returns (uint256) {
        if (property[_funder] == 0) {
            return 0;
        }
        if (totalFunds == 0) {
            return 0;
        }
        uint256 currentProperty = property[_funder];
        uint256 currentFunds = currentProperty +
            (currentProperty / totalFunds) *
            totalInterest;
        return currentFunds;
    }

    function getCurrentQuota(address _lender) external view returns (uint256) {
        return lenders[_lender].aggreedQuota;
    }

    function increaseQuota(address _lender, uint256 _amount)
        external
        onlyOwner
    {
        require(_amount > 0, "Increase amount must be greater than 0");
        require(_lender != address(0), "Invalid lender address");

        Lender storage lender = lenders[_lender];
        lender.aggreedQuota += _amount;

        emit QuotaAdjusted(_lender, lender.aggreedQuota);
    }

    function decreaseQuota(address _lender, uint256 _amount)
        external
        onlyOwner
    {
        require(_amount > 0, "Decrease amount must be greater than 0");
        require(_lender != address(0), "Invalid lender address");
        uint256 currentDue = 0;
        Lender storage lender = lenders[_lender];

        for (uint256 i = 0; i < lender.lendings.length; i++) {
            currentDue += lender.lendings[i].amount;
        }

        require(
            currentDue <= lender.aggreedQuota - _amount,
            "Decrease amount exceeds current due"
        );
        require(
            lender.aggreedQuota >= _amount,
            "Decrease amount exceeds the agreed quota"
        );

        lender.aggreedQuota -= _amount;

        emit QuotaAdjusted(_lender, lender.aggreedQuota);
    }

    function getActiveLoans(
        address _lender,
        uint256 offset,
        uint256 limit
    ) external view returns (Lending[] memory) {
        Lender storage lender = lenders[_lender];
        uint256 totalLoans = lender.lendings.length;
        if (limit > totalLoans - offset) {
            limit = totalLoans - offset;
        }

        Lending[] memory activeLoans = new Lending[](limit);
        uint256 currentIndex = 0;

        for (uint256 i = 0; i < limit; i++) {
            Lending storage lending = lender.lendings[offset + i];
            if (lending.amount > 0) {
                activeLoans[currentIndex] = lending;
                currentIndex++;
            }
        }

        return activeLoans;
    }

    function getTotalLoans(address _lender) external view returns (uint256) {
        Lender storage lender = lenders[_lender];
        return lender.lendings.length;
    }

    function requestLoan(uint256 _amount, uint16 _blockMonths)
        external
        whenNotPaused
    {
        require(
            whitelist[msg.sender] == true,
            "The current address is not able to get a loan"
        );
        require(_amount > 0, "The amount is invalid");
        require(
            lenders[msg.sender].aggreedQuota >= _amount,
            "The agreed quota is insuficent"
        );
        uint256 contractBalance = cUSDToken.balanceOf(address(this));
        require(contractBalance >= _amount, "Contract has insufficient funds");
        lenders[msg.sender].aggreedQuota -= _amount;
        lenders[msg.sender].lendings.push(
            Lending({
                amount: _amount,
                initialAmount: _amount,
                startDate: block.timestamp,
                blockMonths: _blockMonths
            })
        );

        require(cUSDToken.transfer(msg.sender, _amount), "Transfer failed");
        emit LoanRequested(msg.sender, _amount, _blockMonths);
    }

    function addToWhitelist(address _user, uint256 _amount) external onlyOwner {
        require(_user != address(0), "Invalid address");
        require(!whitelist[_user], "User already whitelisted");
        whitelist[_user] = true;
        Lender storage lender = lenders[_user];
        lender.aggreedQuota += _amount;

        emit QuotaAdjusted(_user, lender.aggreedQuota);

        emit WhitelistedUserAdded(_user);
    }

    function removeFromWhitelist(address _user) external onlyOwner {
        require(_user != address(0), "Invalid address");
        require(whitelist[_user], "User not whitelisted");
        whitelist[_user] = false;
        emit WhitelistedUserRemoved(_user);
    }

    function withdrawFunds() external whenNotPaused nonReentrant {
        uint256 userFunds = property[msg.sender];
        require(userFunds > 0, "The user is not able to withdraw");
        require(totalFunds >= userFunds, "Insufficient funds in the contract");
        uint256 userPercentage = (userFunds * 1e18) / totalFunds;
        uint256 userInterest = (totalInterest * userPercentage) / 1e18;
        uint256 amountToWithdraw = userFunds + userInterest;

        uint256 contractBalance = cUSDToken.balanceOf(address(this));
        require(
            contractBalance >= amountToWithdraw,
            "Contract has insufficient funds"
        );

        totalFunds -= userFunds;
        totalInterest -= userInterest;
        property[msg.sender] = 0;
        require(
            cUSDToken.transfer(msg.sender, amountToWithdraw),
            "Failed to send funds"
        );
    }

    function pauseContract() external onlyOwner {
        _pause();
    }

    function unpauseContract() external onlyOwner {
        _unpause();
    }

    function forceWithDraw() external onlyOwner {
        require(
            cUSDToken.transfer(msg.sender, cUSDToken.balanceOf(address(this))),
            "Failed to send funds"
        );
    }

    /*****************************************
     *               Internal                *
     *****************************************/

    function accrueInterest(address _lender, uint256 _lendingIndex) internal {
        Lending storage lending = lenders[_lender].lendings[_lendingIndex];
        uint256 timeElapsed = block.timestamp - lending.startDate;

        if (timeElapsed >= INTEREST_PERIOD) {
            uint256 periodsElapsed = timeElapsed / INTEREST_PERIOD;
            uint256 ratePerPeriod = INTEREST_RATE_PER_DAY; // Esta es la tasa diaria sin escalar

            uint256 compoundInterest = lending.amount;
            for (uint256 i = 0; i < periodsElapsed; i++) {
                // Escalar y luego desescalar para prevenir el redondeo a cero.
                compoundInterest =
                    (compoundInterest * (10**8 + ratePerPeriod)) /
                    10**8;
            }

            uint256 interestAmount = compoundInterest - lending.amount;
            lending.amount = compoundInterest;
            totalInterest += interestAmount;

            lending.startDate += periodsElapsed * INTEREST_PERIOD;
        }
    }

    function removeLending(address _lender, uint256 _lendingIndex) internal {
        Lender storage lender = lenders[_lender];
        uint256 lastLendingIndex = lender.lendings.length - 1;

        if (_lendingIndex < lastLendingIndex) {
            lender.lendings[_lendingIndex] = lender.lendings[lastLendingIndex];
        }

        lender.lendings.pop();
    }
}
