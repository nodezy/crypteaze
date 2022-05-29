// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Allows another user(s) to change contract variables
contract Authorizable is Ownable {

    mapping(address => bool) public authorized;

    modifier onlyAuthorized() {
        require(authorized[_msgSender()] || owner() == address(_msgSender()));
        _;
    }

    function addAuthorized(address _toAdd) onlyOwner public {
        require(_toAdd != address(0));
        authorized[_toAdd] = true;
        
    }

    function removeAuthorized(address _toRemove) onlyOwner public {
        require(_toRemove != address(0));
        require(_toRemove != address(_msgSender()));
        authorized[_toRemove] = false;
    }

}

interface ITeazeFarm {
    function getUserStaked(address _holder) external view returns (bool);
    function increaseSBXBalance(address _address, uint256 _amount) external;
}

interface IDEXRouter {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract TeazeLotto is Ownable, Authorizable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address farmingContract;
    IERC20 simpbux;

    mapping(address => uint256) public lastSpin; //Mapping for last user spin on the SimpWheel of Fortune
    uint simpWheelBaseReward = 25;
    uint256 public spinFee = 0.0005 ether; //Fee the contract takes for each attempt at spinning the SimpWheel
    mapping(uint => bool) private lastrand; //Mapping to store bitwise operator for randomness

    address _teazetoken = 0x4faB740779C73aA3945a5CF6025bF1b0e7F6349C; //teaze token

    IERC20 teazetoken = IERC20(_teazetoken); 

    IDEXRouter router;
    
    address WETH;

    uint256 marketBuyGas = 450000;

    uint jackpotLimit = 2 ether;

    uint256 spinFrequency = 86400;

    constructor(address _farmingContract, address _simpbux, address _router) {
       farmingContract = _farmingContract;
       simpbux = IERC20(_simpbux);
       lastrand[0] = true;
       authorized[owner()] = true;

       router = _router != address(0)
            ? IDEXRouter(_router)
            : IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); //0xCc7aDc94F3D80127849D2b41b6439b7CF1eB4Ae0 pcs test router
        WETH = router.WETH();
    }
    
    receive() external payable {}


    function SpinSimpWheel(address _holder) external payable nonReentrant returns (uint256 userroll,uint256 simbuxwinnings,bool jackpotwinner) {

        bool staked = ITeazeFarm(farmingContract).getUserStaked(_holder);
        require(msg.sender == address(farmingContract), "Spinning not allowed outside of the farming contract");
        require(staked, "User must be staked to spin the SimpWheel of Fortune");
        if(lastSpin[_holder] != 0) {
            require(block.timestamp.sub(lastSpin[_holder]) >= spinFrequency, "Not eligible to spin yet");
        }
        require(msg.value == spinFee, "Please include the spin fee to spin the SimpWheel");

        uint256 roll;

        if(lastrand[0]) {
            roll = uint256(blockhash(block.number-1)) % 1000; //get user roll 0-99
            lastrand[0] = false;
        } else {
            roll = uint256(keccak256(abi.encodePacked(block.timestamp))) % 1000; //get user roll 0-99
            lastrand[0] = true;
        }
        
        roll = roll.add(1); //normalize 1-1000

        uint256 userReward;
        bool jackpotWinner = false;

        payable(this).transfer(spinFee);
        lastSpin[_holder] = block.timestamp;

        if (roll > 499) { //winning of some kind

            //(userRoll - 500) + baseReward) / 2 

            userReward = (simpWheelBaseReward.add(roll.sub(499))).div(2);
            ITeazeFarm(farmingContract).increaseSBXBalance(_holder, userReward);

            if (roll == 1000) { //wins jackpot

            jackpotWinner = true;
            payable(_holder).transfer(address(this).balance.mul(80).div(100));

            } else {
                if(address(this).balance > jackpotLimit) {

                    uint256 netamount = address(this).balance.mul(20).div(100);
                    payable(_holder).transfer(netamount);
                    address[] memory path = new address[](2);

                    path[0] = WETH;
                    path[1] = _teazetoken;

                    router.swapExactETHForTokensSupportingFeeOnTransferTokens{value:netamount, gas:marketBuyGas}(
                        0,
                        path,
                        address(farmingContract),
                        block.timestamp
                    );
                }
            }

            return(roll,userReward,jackpotWinner);


        } else {
            return (roll,0, false);
        }       
        
    }

    function changeBaseReward(uint256 _baseReward) external onlyAuthorized {
        simpWheelBaseReward = _baseReward;
    }

    function changeSpinFee(uint256 _spinFee) external onlyAuthorized {
        spinFee = _spinFee;
    }

    function changeJackpotLimit(uint256 _limit) external onlyAuthorized {
        jackpotLimit = _limit;
    }

    function changeMarketBuyGas(uint256 _gas) external onlyAuthorized {
        marketBuyGas = _gas;
    }

    function changeSpinFrequency(uint256 _period) external onlyAuthorized {
        spinFrequency = _period;
    }


}
