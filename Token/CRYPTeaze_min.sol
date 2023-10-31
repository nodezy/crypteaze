// SPDX-License-Identifier: MIT

pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * BEP20 standard interface.
 */
interface IBEP20 {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
    function name() external view returns (string memory);
    function getOwner() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address _owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IOracle {
    function getdiscount(uint256 amount) external returns (uint256 discount);
}

interface IDEXFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
    function balanceOf(address owner) external view returns (uint);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
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

interface IDirectory {
    function getNFTMarketing() external view returns (address); 
    function getLotto() external view returns (address);
    function getCrates() external view returns (address);
    function getOracle() external view returns (address);
}

contract CRYPTeaze is IBEP20, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    address WETH;
    address DEAD = 0x000000000000000000000000000000000000dEaD;
    address ZERO = 0x0000000000000000000000000000000000000000;

    IWETH WETHrouter;
    
    string constant _name = "CRYPTeaze";
    string constant _symbol = "Teaze";
    uint8 constant _decimals = 9;

    uint256 _totalSupply = 2000000000000 * (10 ** _decimals);
    uint256 public _maxTxAmountBuy = _totalSupply;
    uint256 public _maxTxAmountSell = _totalSupply; 
    uint256 public _maxWalletToken = _totalSupply; 

    struct Partners {
        address token_addr;
        uint256 minHoldAmount;
        uint256 discount;
        bool enabled;
    }

    mapping (uint256 => Partners) private partners;
    address[] partneraddr;
    mapping (address => bool) partnerAdded;

    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;

    mapping (address => bool) public isFeeExempt;
    mapping (address => bool) public isTxLimitExempt;
    mapping (address => bool) public isDividendExempt;
    mapping (address => bool) public isBot;

    uint256 initialBlockLimit = 1;

    uint256 public totalFee = 50; //(5%)
    uint256 public lotteryFee = 250;
    uint256 public nftmarketingFee = 100;
    uint256 public lootboxFee = 250;
      
    uint256 public feeDenominator = 1000;
    uint256 discountOffset = 1;
    uint256 public partnerFeeLimiter = 50;
    uint256 public WETHaddedToPool;
    uint256 public totalReflect;
    uint256 public totalLottery;
    uint256 public totalNFTmarketing;
    uint256 public totalLootBox;

    IDEXRouter public router;
    IDirectory public directory;
    address public pair;

    uint256 public launchedAt;

    bool public swapEnabled = false;
    bool public lootContractActive = true;
    bool public nftWalletActive = false;
    bool public lotteryContractActive = true;
    bool public teamWalletDeposit = true;
    bool public enablePartners = false;
    bool public enableOracle = false;
    bool public airdropEnabled = false;
    bool public launchEnabled = true;

    bool inSwap;
    
    
    uint256 distributorGas = 750000;
    uint256 walletGas = 40000;
    uint256 depositGas = 350000;

    uint256 public swapThreshold = 1000000000000000; //100k tokens
    
    modifier swapping() { inSwap = true; _; inSwap = false; }

    constructor (address _directory) {
        
       // router = IDEXRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);  pancake v2

       router = IDEXRouter(0xD99D1c33F9fC3444f8101754aBC46c52416550D1); //test pancakeswap.finance router

       // router = IDEXRouter(0xCc7aDc94F3D80127849D2b41b6439b7CF1eB4Ae0);  //test pancake router https://pcs.nhancv.com

        directory = IDirectory(_directory);

        address _presaler = msg.sender;
            
        WETH = router.WETH();
        
        pair = IDEXFactory(router.factory()).createPair(WETH, address(this));
        
        _allowances[address(this)][address(router)] = type(uint256).max;

        isFeeExempt[_presaler] = true;
        isDividendExempt[_presaler] = true;
        isTxLimitExempt[_presaler] = true;
        isTxLimitExempt[DEAD] = true;
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        isDividendExempt[DEAD] = true;

        _balances[_presaler] = _totalSupply;
        emit Transfer(address(0), _presaler, _totalSupply);
    }

    receive() external payable {}

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function decimals() external pure override returns (uint8) { return _decimals; }
    function symbol() external pure override returns (string memory) { return _symbol; }
    function name() external pure override returns (string memory) { return _name; }
    function getOwner() external view override returns (address) { return owner(); }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }


    function approve(address spender, uint256 amount) public override returns (bool) {
        if(owner() != msg.sender){require(launchEnabled, "Liquid has not been added yet!");}
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function approveMax(address spender) external returns (bool) {
        return approve(spender, type(uint256).max);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _tF(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != type(uint256).max){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _tF(sender, recipient, amount);
    }

    function _tF(address s, address r, uint256 amount) internal returns (bool) {
        require(amount > 0, "Insufficient Amount: cannot send 0 Teaze");
        
        if(airdropEnabled){ return _basicTransfer(s, r, amount); }
        if(inSwap){ return _basicTransfer(s, r, amount); }

        checkTxLimit(s, r, amount);

        if (r == pair) {
            
            if(shouldSwapBack()){ swapBack(); }
        }

        if(!launched() && r == pair){ require(_balances[s] > 0); launch(); }

        _balances[s] = _balances[s].sub(amount, "Insufficient Balance");

        uint256 amountReceived = shouldTakeFee(s) && shouldTakeFee(r) ? takeFee(s, r, amount) : amount;

        
        if(r != pair && !isTxLimitExempt[r]){
            uint256 contractBalanceRecepient = balanceOf(r);
            require(contractBalanceRecepient + amountReceived <= _maxWalletToken, "Exceeds maximum wallet token amount"); 
        }
        
        _balances[r] = _balances[r].add(amountReceived);
       
        emit Transfer(s, r, amountReceived);
        return true;
    }
    
    function _basicTransfer(address sender, address recipient, uint256 amount) internal returns (bool) {
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);
        return true;
    }
    
    function manualBurn(uint256 amount) external onlyOwner returns (bool) {
        return _basicTransfer(address(this), DEAD, amount);
    }

    function checkTxLimit(address sender, address receiver, uint256 amount) internal view {
        if(sender == pair) {require(amount <= _maxTxAmountBuy || isTxLimitExempt[receiver], "Buy TX Limit Exceeded");}
        if(receiver == pair) {require(amount <= _maxTxAmountSell || isTxLimitExempt[sender], "Sell TX Limit Exceeded");}
    }

    function shouldTakeFee(address sender) internal view returns (bool) {
        return !isFeeExempt[sender];
    }

    function getTotalFee(bool bot) public view returns (uint256) {
        // Anti-bot, fees as 99% for the first block
        if(launchedAt + initialBlockLimit >= block.number || bot){ return feeDenominator.sub(1); }
        return totalFee;
    }

    function takeFee(address sender, address recipient, uint256 amount) internal returns (uint256) {
        uint256 feeAmount; 
        uint256 regularFee = getTotalFee(isBot[sender]);
        uint256 discountFee = 0;

        if (enablePartners && recipient != pair && sender == pair) {
            //scan wallet for BEP20 tokens matching those in struct 

            uint256 partnerCount = partneraddr.length;
            
            for (uint256 x = 0; x <= partnerCount; ++x) {

                Partners storage tokenpartners = partners[x];

                if (tokenpartners.enabled) {

                   if(IBEP20(address(tokenpartners.token_addr)).balanceOf(address(recipient)) >= tokenpartners.minHoldAmount) {

                       discountFee = discountFee.add(tokenpartners.discount);

                   } 

                } 
            }           

        }
        
        if (enableOracle && recipient != pair && sender == pair) {

            uint256 discountAmount = IOracle(directory.getOracle()).getdiscount(amount);
            discountAmount = discountAmount.div(100000000);
            discountAmount = discountAmount.add(discountOffset);
            discountFee = discountFee.add(discountAmount);
        
        } 

        if (discountFee == 0) {

            feeAmount = amount.mul(regularFee).div(feeDenominator);

        } else {

            if (discountFee > regularFee.mul(partnerFeeLimiter).div(100)) {
                discountFee = regularFee.mul(partnerFeeLimiter).div(100);
            } else {
                discountFee = regularFee.sub(discountFee);
            }
            
            feeAmount = amount.mul(discountFee).div(feeDenominator);
        }

        _balances[address(this)] = _balances[address(this)].add(feeAmount);
        emit Transfer(sender, address(this), feeAmount);
        
        return amount.sub(feeAmount);
    }

    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }

    function swapBack() internal swapping {

        uint256 amountToSwap = IBEP20(address(this)).balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        uint256 balanceBefore = address(this).balance;

        //Exchange the built up tokens
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp           
        );

        //Calculate the distribution
        uint256 amountBNB = address(this).balance.sub(balanceBefore);
        uint256 amountBNBReflection;

        //Deposit to the team wallets
        if (teamWalletDeposit) {

        uint256 amountBNBlotto;
        uint256 amountBNBnft;
        uint256 amountBNBloot;

        uint256 amountTotatBNBFee;

            if (lotteryContractActive) {
                amountBNBlotto = amountBNB.mul(lotteryFee).div(feeDenominator);

                (bool successTeam1, /* bytes memory data */) = payable(directory.getLotto()).call{value: amountBNBlotto, gas: walletGas}("");
                require(successTeam1, "Lottery contract rejected BNB transfer");

                totalLottery = totalLottery.add(amountBNBlotto);
            }
                        
            if (nftWalletActive) {
                amountBNBnft = amountBNB.mul(nftmarketingFee).div(feeDenominator);

                (bool successTeam3, /* bytes memory data */) = payable(directory.getNFTMarketing()).call{value: amountBNBnft, gas: walletGas}("");
                require(successTeam3, "NFT marketing wallet rejected BNB transfer");

                totalNFTmarketing = totalNFTmarketing.add(amountBNBnft);
            } 

            if (lootContractActive) {
                amountBNBloot = amountBNB.mul(lootboxFee).div(feeDenominator);

                (bool successTeam4, /* bytes memory data */) = payable(directory.getCrates()).call{value: amountBNBloot, gas: walletGas}("");
                require(successTeam4, "Staking pool wallet rejected BNB transfer");

                totalLootBox = totalLootBox.add(amountBNBloot);
            } 
            
            amountTotatBNBFee = amountTotatBNBFee.add(amountBNBloot).add(amountBNBlotto).add(amountBNBnft);
            amountBNBReflection = amountBNB.sub(amountTotatBNBFee); 
            totalReflect = totalReflect.add(amountBNBReflection);
        
        }  else {

            amountBNBReflection = amountBNB;
            totalReflect = totalReflect.add(amountBNBReflection);
        } 
                
    }

    function launched() internal view returns (bool) {
        return launchedAt != 0;
    }

    function launch() internal {
        launchedAt = block.number;
    }
    
    function setInitialBlockLimit(uint256 blocks) external onlyOwner {
        require(blocks > 0, "Blocks should be greater than 0");
        initialBlockLimit = blocks;
    }

    function setBuyTxLimit(uint256 amount) external onlyOwner {
        _maxTxAmountBuy = amount;
    }
    
    function setSellTxLimit(uint256 amount) external onlyOwner {
        require(amount >= 250000000000000000, "Sell limit must not be less than 250M tokens");
        _maxTxAmountSell = amount;
    }
    
    function setMaxWalletToken(uint256 amount) external onlyOwner {
        require(amount >= 250000000000000000, "Wallet limit must not be less than 250M tokens");
        _maxWalletToken = amount;
    }
    
    function setBot(address _address, bool toggle) external onlyOwner {
        isBot[_address] = toggle;
        _setIsDividendExempt(_address, toggle);
    }

    function _setIsDividendExempt(address holder, bool exempt) internal {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
    }
    
    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        _setIsDividendExempt(holder, exempt);
    }

    function setIsFeeExempt(address holder, bool exempt) external onlyOwner {
        isFeeExempt[holder] = exempt;
    }

    function setIsTxLimitExempt(address holder, bool exempt) external onlyOwner {
        isTxLimitExempt[holder] = exempt;
    }

    function setFee(uint256 _totalFee) external onlyOwner {
        //Total fees has to be between 0 and 10 percent
        require(_totalFee >= 0 && _totalFee <= 100, "Total Fee must be between 0 and 100 (100 = ten percent)");
        totalFee = _totalFee;
    }

    function setTaxes (uint256 _lotteryFee, uint256 _nftmarketingFee, uint256 _lootboxFee) external onlyOwner {

        require(totalFee >= _lotteryFee.add(_nftmarketingFee).add(_lootboxFee), "Total taxes must not exceen total fee");

        lotteryFee = _lotteryFee;
        nftmarketingFee = _nftmarketingFee;
        lootboxFee = _lootboxFee;
    }
        
    function setSwapBackSettings(bool _enabled, uint256 _amount) external onlyOwner {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }
    
    function getCirculatingSupply() public view returns (uint256) {
        return _totalSupply.sub(balanceOf(DEAD)).sub(balanceOf(ZERO));
    }

    function setTeamWalletDeposit(bool _status) external onlyOwner {
        teamWalletDeposit = _status;
    }

    function viewTeamWalletInfo() public view returns (uint256 reflectDivs, uint256 buybackDivs, uint256 nftDivs, uint256 stakeDivs) {
        return (totalReflect, totalLottery, totalNFTmarketing, totalLootBox);
    }

    // This will allow owner to rescue BNB sent by mistake directly to the contract
    function rescueBNB() external onlyOwner {
        address payable _owner = payable(msg.sender);
        _owner.transfer(address(this).balance);
    }

    // Converts to WBNB any BNB held in the contract (from sweep() function, for example)
    function convertBNBtoWBNB() external onlyOwner {
         IWETH(WETH).deposit{value : address(this).balance}();
    }

    // Function to allow admin to claim *other* ERC20 tokens sent to this contract (by mistake)
    function transferBEP20Tokens(address _tokenAddr, address _to, uint _amount) external onlyOwner {
        IBEP20(_tokenAddr).transfer(_to, _amount);
    }

  

    function setStakePoolActive(bool _status) external onlyOwner {
        lootContractActive = _status; 
    }

    function setNFTPoolActive(bool _status) external onlyOwner {
        nftWalletActive = _status; 
    }

    function changeContractGas(uint256 _distributorgas, uint256 _walletgas) external onlyOwner {
        require(_distributorgas > 0, "distributor cannot be equal to zero");
        require(_walletgas > 0, "distributor cannot be equal to zero");
        
        distributorGas = _distributorgas;
        walletGas = _walletgas;
    
    }

    function isContract(address addr) internal view returns (bool) {
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

        bytes32 codehash;
        assembly {
            codehash := extcodehash(addr)
        }
            return (codehash != 0x0 && codehash != accountHash);
    }

    function addPartnership(address _tokencontract, uint256 _minHoldAmount, uint256 _percent) external onlyOwner {

        require(_tokencontract != DEAD && _tokencontract != ZERO && _tokencontract != pair, "Please input a valid token contract address");
        require(isContract(_tokencontract), "Please input an actual token contract");
        require(!partnerAdded[_tokencontract], "Contract already added. To change parameters please remove first.");
        require(_minHoldAmount > 0, "Min hold must be greater than zero");
        require(_percent <= totalFee, "Discount cannot be greater than total tax");

        uint256 partnerCount = partneraddr.length;
        
        Partners storage tokenpartners = partners[partnerCount];

            tokenpartners.token_addr = _tokencontract;
            tokenpartners.minHoldAmount = _minHoldAmount;
            tokenpartners.discount =_percent;
            tokenpartners.enabled = true;

            partnerAdded[_tokencontract] = true;
            partneraddr.push(_tokencontract);
        
    }

    function removePartnership(address _tokencontract) external onlyOwner {

        uint256 partnerCount = partneraddr.length;

        if (partnerCount > 0) {
            for (uint256 x = 0; x < partnerCount; ++x) {

                Partners storage tokenpartners = partners[x];

                if (address(tokenpartners.token_addr) == address(_tokencontract)) {

                    if (x == partnerCount) {
                        tokenpartners.token_addr = ZERO;
                        tokenpartners.minHoldAmount = 0;
                        tokenpartners.discount = 0;
                        tokenpartners.enabled = false;

                        partnerAdded[_tokencontract] = false;

                        partneraddr.pop();
                        
                    } else {

                        Partners storage tokenpartnerscopy = partners[partneraddr.length-1];

                        tokenpartners.token_addr = tokenpartnerscopy.token_addr;
                        tokenpartners.minHoldAmount = tokenpartnerscopy.minHoldAmount;
                        tokenpartners.discount = tokenpartnerscopy.discount;
                        tokenpartners.enabled = true;

                        partnerAdded[_tokencontract] = false;

                        tokenpartnerscopy.token_addr = ZERO;
                        tokenpartnerscopy.minHoldAmount = 0;
                        tokenpartnerscopy.discount = 0;
                        tokenpartnerscopy.enabled = false;

                        partneraddr[x] = partneraddr[partneraddr.length-1];
                        partneraddr.pop();

                    }
                    
                }
            }

        } else {
            return;
        }
    }

    function getPartnershipIndex() external view returns (uint256) {
        return partneraddr.length;
    }

    function viewPartnership(uint256 _index) external view returns (string memory name_, string memory symbol_, uint8 decimals_, address tokencontract, uint256 minHoldAmount, uint256 discount, bool enabled) {
        Partners storage tokenpartners = partners[_index];
        string memory token_name = IBEP20(tokenpartners.token_addr).name();
        string memory token_symbol = IBEP20(tokenpartners.token_addr).symbol();
        uint8 token_decimals = IBEP20(tokenpartners.token_addr).decimals();
        return (token_name, token_symbol, token_decimals, tokenpartners.token_addr,tokenpartners.minHoldAmount,tokenpartners.discount,tokenpartners.enabled);
    }

    function setEnablePartners(bool _status) external onlyOwner {
        enablePartners = _status;
    }

    function setEnableOracle(bool _status) external onlyOwner {
        enableOracle = _status;
    }

    //value of 100 allows partner taxes to reduce 0% of totalFee tax, 50 = 50% of total tax (default), 1 allows 99% tax reduction of total tax for partners
    function setPartnerFeeLimiter(uint256 _limiter) external onlyOwner {
        require(_limiter <= 100 && _limiter >= 1, "fee limiter must be between 1 and 100");
        partnerFeeLimiter = _limiter;
    }

    //once the airdrop is complete, this function turns off _basicTransfer permanently for airdropEnabled
    function setAirdropDisabled() external onlyOwner {
        airdropEnabled = false;
    }

    //once the liquid is added, this function turns on launchEnabled permanently
    function setLaunchEnabled() external onlyOwner {
        require(!airdropEnabled, "Please disable airdrop mode first");
        launchEnabled = true;
    }

    function setDiscountOffset(uint256 _offset) external onlyOwner {
        discountOffset = _offset;
    }

    function changeDirectory(address _directory) external onlyOwner {
        directory = IDirectory(_directory);
    }

}

