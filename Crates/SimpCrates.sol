// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./auth.sol";

interface Inserter {
    function makeActive() external; 
    function getNonce() external view returns (uint256);
    function getRandMod(uint256 _extNonce, uint256 _modifier, uint256 _modulous) external view returns (uint256);
}

interface ITeazePacks {
    function getCurrentNFTID() external view returns (uint256);
    function getNFTURI(uint256 _nftid) external view returns (string memory);
    function getPackInfo(uint256 _packid) external view returns (uint256,uint256,uint256,uint256,bool,bool);   
    function getNFTClass(uint256 _nftid) external view returns (uint256);
    function getNFTPercent(uint256 _nftid) external view returns (uint256);
    function getLootboxAble(uint256 _nftid) external view returns (bool); 
    function getPackTimelimitCrates(uint256 _nftid) external view returns (bool);
    function getNFTExists(uint256 _nftid) external view returns (bool);
}

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
   // function mint(address _recipient, string memory _uri, uint _packNFTid) external returns (uint256); 
}

contract SimpCrates is Ownable, Authorizable, Whitelisted, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    
    Counters.Counter public _LootBoxIds; //so we can track amount of lootboxes in creation
    Counters.Counter public unclaimedBoxes; //so we can limit the amount of active unclaimed lootboxes
    Counters.Counter public claimedBoxes; //so we can track the total amount of claimed lootboxes

    struct LootboxInfo {
        uint256 rollNumber; //number needed to claim reward
        uint256 rewardAmount; //amount of BNB in lootbox
        uint256 percentTotal; //total percent of combined NFT mintPercent
        uint256 mintclassTotal; //total mintclass (higher mintclass = higher bnb reward)
        uint256 timeend; //timestamp lootbox will expire
        address claimedBy; //address that unlocked the lootbox
        bool claimed; //unclaimed = false, claimed = true
    }

    mapping(uint256 => LootboxInfo) public lootboxInfo; // Info of each lootbox.
    uint256[] public activelootboxarray; //Array to store each active lootbox id so we can view.
    uint256[] private inactivelootboxarray; //Array to store each active lootbox id so we can view.
    
    mapping(uint256 => uint256[]) public LootboxNFTids; // array of NFT ID's listed under each lootbox.
    mapping (uint256 => bool) public claimedNFT; //Whether the nft tokenID has been used to claim a lootbox or not.

    Inserter private inserter;
    ITeazePacks public teazepacks;
    ITeazeNFT public nft;

    address public nftContract; 
    address public packsContract; // Address of the associated farming contract.
    
    uint256 private heldAmount = 0; //Variable to determine how much BNB is in the contract not allocated to a lootbox
    uint256 public maxRewardAmount = 300000000000000006; //Maximum reward of a lootbox (simpcrate)
    uint256 public rewardPerClass = 33333333333333334; //Amount each class # adds to reward (maxRewardAmount / nftPerLootBox)
    uint256 public nftPerLootbox = 3;
    uint256 public lootboxdogMax = 59; //Maximum roll the lootbox will require to unlock it
    uint256 public lootboxdogNormalizer = 31;
    uint256 private randNonce;
    uint256 public rollFee = 0.001 ether; //Fee the contract takes for each attempt at opening the lootbox once the user has the NFTs
    uint256 public unclaimedLimiter = 30; //Sets total number of unclaimed lootboxes that can be active at any given time
    uint256 timeEnder = 86400; //time multiplier for when lootboxes end, based on mintclass (defautl 1 week)
    uint256 timeEndingFactor = 234; //will be multiplied by timeEnder and mintClass to get dynamic lifetimes on crates based on difficulty
    bool public boxesEnabled = true;

    constructor(address _packsContract, address _nftcontract, address _inserter) {
        nftContract =_nftcontract;
        packsContract = _packsContract;
        teazepacks = ITeazePacks(_packsContract);
        nft = ITeazeNFT(_nftcontract);
        inserter = Inserter(_inserter);
        randNonce = inserter.getNonce();
        inserter.makeActive();
        addWhitelisted(owner());
    }

    receive() external payable {}

    //returns the balance of the erc20 token required for validation
    function checkBalance(address _token, address _holder) public view returns (uint256) {
        IERC20 token = IERC20(_token);
        return token.balanceOf(_holder);
    }
    
    function setpacksContract(address _address) public onlyAuthorized {
        packsContract = _address;
    }
    
    // This will allow to rescue ETH sent by mistake directly to the contract
    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    // Function to allow admin to claim *other* ERC20 tokens sent to this contract (by mistake)
    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) public onlyOwner {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }


    function checkIfLootbox() public {
        
        //if (heldAmount.add(maxRewardAmount) <= address(this).balance && nftids > 0) {
        if (true) {

            //get 'lootboxable' NFT
            
            uint256 count = 0;
            uint256 nftids = teazepacks.getCurrentNFTID();
            uint256[] memory lootableNFT = new uint256[](nftids);

            for (uint x=1;x<=nftids;x++) {
                if (teazepacks.getLootboxAble(x) && teazepacks.getPackTimelimitCrates(x)) {
                    lootableNFT[count]=x;
                    count++;
                }
            }

            uint lootableNFTcount = lootableNFT.length;

            if (lootableNFT.length >= 3) {

                //create lootbox

                randNonce++;

                _LootBoxIds.increment();

                uint256 lootboxid = _LootBoxIds.current();

                uint256 mintclassTotals = 0;
                uint256 percentTotals = 0;
                
                uint256 nftroll = 0;
                
                
                for (uint256 x = 1; x <= nftPerLootbox; ++x) {

                    nftroll = inserter.getRandMod(randNonce, x, lootableNFTcount.mul(100)); //get a random nft
                    nftroll = nftroll+100;
                    nftroll = nftroll.div(100);
                    nftroll = nftroll-1;

                    LootboxNFTids[lootboxid].push(lootableNFT[nftroll]);

                    mintclassTotals = mintclassTotals.add(teazepacks.getNFTClass(lootableNFT[nftroll]));
                    percentTotals = percentTotals.add(teazepacks.getNFTPercent(lootableNFT[nftroll]));
                    
                }                  

                uint256 boxreward = rewardPerClass.mul(mintclassTotals);

                uint256 boxroll = inserter.getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(block.timestamp)))%100), lootboxdogMax); //get box roll 0-89
                boxroll = boxroll+lootboxdogNormalizer; //normalize

                LootboxInfo storage lootboxinfo = lootboxInfo[lootboxid];

                lootboxinfo.rollNumber = boxroll;
                lootboxinfo.mintclassTotal = mintclassTotals;
                lootboxinfo.percentTotal = percentTotals;
                lootboxinfo.rewardAmount = boxreward;
                lootboxinfo.timeend = block.timestamp.add(mintclassTotals.mul(timeEnder.mul(timeEndingFactor)).div(100));
                lootboxinfo.claimedBy = address(0);
                lootboxinfo.claimed = false;
                

                //update heldAmount
                heldAmount = heldAmount.add(boxreward);

                unclaimedBoxes.increment();

                activelootboxarray.push(lootboxid); //add lootboxid to loopable array for view function

            }
                    
        }
    }

    function ClaimLootbox(uint256 _lootboxid) external payable nonReentrant returns (bool winner, bool used, uint256 roll, uint256 dogroll) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        require(!lootboxinfo.claimed, "E21");
        require(msg.value == rollFee, "E22");

        //check wallet against Simpcrate NFT

        uint256 lootboxlength = LootboxNFTids[_lootboxid].length;

        bool result = false;
        bool hasNFTresult = true;
        bool NFTunusedresult = false;
        uint256[] memory tokens = new uint256[](lootboxlength); //create array 
        uint256 tokentemp;
        uint256 userroll = 0;
        uint256 lootbox = _lootboxid; 

        for (uint x = 0; x < lootboxlength; x++) {

            (result,tokentemp) = checkWalletforNFT(x,_msgSender(), lootbox);
            hasNFTresult = hasNFTresult && result;
            tokens[x] = tokentemp;
            NFTunusedresult = NFTunusedresult || claimedNFT[tokentemp];
        }

        if (hasNFTresult && !NFTunusedresult) { //user has all NFT, none have been used to obtain SimpCrate, roll to beat the dog
            userroll = inserter.getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(_msgSender())))%100), 100); 
            userroll = userroll+1;

            if (userroll >= lootboxinfo.rollNumber) {
                //transfer winnings to user, update struct, mark tokenIDs as ineligible for future lootboxes
                payable(_msgSender()).transfer(lootboxinfo.rewardAmount);
                heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);

                for (uint256 z=0; z<tokens.length; z++) {
                    claimedNFT[tokens[z]] = true;
                }

                lootboxinfo.claimed = true;
                lootboxinfo.claimedBy = _msgSender();

                claimedBoxes.increment();
                unclaimedBoxes.decrement();

                retireLootbox(_lootboxid);

            } else {
                //put logic here to expire lootbox and put lootbox reward back into pool for a new one
                if (block.timestamp > lootboxinfo.timeend) {
                    claimedBoxes.increment();
                    unclaimedBoxes.decrement();
                    heldAmount = heldAmount.add(lootboxinfo.rewardAmount);
                    retireLootboxExpired(_lootboxid);
                }
            }
        }

        payable(this).transfer(rollFee);

        return (hasNFTresult, NFTunusedresult, userroll, lootboxinfo.rollNumber);

    }   

    function checkWalletforNFT(uint256 _position, address _holder, uint256 _lootbox) public view returns (bool nftpresent, uint256 tokenid) {

        uint256 nftbalance = IERC721(nftContract).balanceOf(_holder);
        bool result;
        uint256 token;

         for (uint256 y = 0; y < nftbalance; y++) {

             string memory boxuri = teazepacks.getNFTURI(LootboxNFTids[_lootbox][_position]);
             string memory holderuri = nft.tokenURI(nft.tokenOfOwnerByIndex(_holder, y));

            if (keccak256(bytes(boxuri)) == keccak256(bytes(holderuri))) {
                result = true;
                token = nft.tokenOfOwnerByIndex(_holder, y);
            } else {
                result = false;
                token = 0;
            }

        }

        return (result, tokenid);
    }

    function checkIfWinnwer(uint256 _lootboxid, address _holder) external view returns (bool) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        //check wallet against Simpcrate NFT

        uint256 lootboxlength = LootboxNFTids[_lootboxid].length;

        bool result = false;
        bool hasNFTresult = true;
        bool NFTunusedresult = false;
        uint256 tokentemp;

        for (uint x = 0; x < lootboxlength; x++) {

            (result,tokentemp) = checkWalletforNFT(x, _holder, _lootboxid);
            hasNFTresult = hasNFTresult && result;
            NFTunusedresult = NFTunusedresult || claimedNFT[tokentemp];
        }

        if ((lootboxinfo.claimed == false) && hasNFTresult && !NFTunusedresult) {return true;} else {return false;}       

    }

    function updateRewardAmounts(uint256 _maxRewardAmount, uint256 _nftPerLootbox, bool _auth) external onlyAuthorized {

        //the larger the _maxRewardAmount the longer it will take the contract to create a lootbox
        //the more _nftPerLootbox the harder they will be to open, taking longer for users to collect the appropriate NFTs

        //we can set some limitations here or override them with _auth = true

        if (!_auth) {
            require(_maxRewardAmount < 0.5 ether, "E23");
            require(_nftPerLootbox <= 5, "E24");
        }

        maxRewardAmount = _maxRewardAmount;
        nftPerLootbox = _nftPerLootbox;

        rewardPerClass = maxRewardAmount.div(nftPerLootbox);

    }

    function changeLootboxDogMax(uint256 _dogroll) external onlyAuthorized {
        require(_dogroll >= 10, "E25");
        require(_dogroll <= 59, "E26");

        lootboxdogMax = _dogroll;
    }

    function changeRollFee(uint256 _rollFee) external onlyAuthorized {
        require(_rollFee >= 0 && _rollFee <= 0.01 ether, "E27");

        rollFee = _rollFee;
    }

    function changeUnclaimedLimiter(uint256 _limit, bool _auth) external onlyAuthorized {

        if (!_auth) {
            require(_limit <= 50, "E28");
        }

        unclaimedLimiter = _limit;
        
    }

    function viewActiveSimpCrates() external view returns (uint256[] memory lootboxes){

        return activelootboxarray;

    }

    function viewInactiveSimpCrates(uint _startingpoint, uint _length) external view returns (uint256[] memory) {

        uint256[] memory array = new uint256[](_length); 

        //Loop through the segment at the starting point
        for(uint x = 0; x < _length; x++) {
          array[x] = inactivelootboxarray[_startingpoint.add(x)];
        }   

        return array;

    }
    
    function getInactiveSimpCratesLength() external view returns (uint256) {
        return inactivelootboxarray.length;
    }

    function setBoxesEnabled(bool _status) external onlyAuthorized {
        boxesEnabled = _status;
    }

    function getLootBoxDogroll(uint256 _lootboxid) external view returns (uint256) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];
        return lootboxinfo.rollNumber;
    }

    function retireLootbox(uint256 _lootboxid) internal {
        uint arraylength = activelootboxarray.length;

        //Remove lootboxid from active array
        for(uint x = 0; x < arraylength; x++) {
            if (activelootboxarray[x] == _lootboxid) {
                activelootboxarray[x] = activelootboxarray[arraylength-1];
                activelootboxarray.pop();
            }
        }       

        //Add lootboxid to inactive array
        inactivelootboxarray.push(_lootboxid);

    }

    function retireLootboxExpired(uint256 _lootboxid) internal {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);
        lootboxinfo.claimedBy = address(0x000000000000000000000000000000000000dEaD);
        lootboxinfo.claimed = true;

        retireLootbox(_lootboxid);
    }

    function retireLootboxAdmin(uint256 _lootboxid) external onlyAuthorized {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);
        lootboxinfo.claimedBy = address(0x000000000000000000000000000000000000dEaD);
        lootboxinfo.claimed = true;

        retireLootbox(_lootboxid);
    }

    function createLootboxAdmin(uint256 _nftid1, uint256 _nftid2, uint256 _nftid3, uint256 _rewardAmt) external payable onlyAuthorized {

        require(msg.value == _rewardAmt, "E31");

        randNonce++;

        _LootBoxIds.increment();

        uint256 lootboxid = _LootBoxIds.current();

        uint256 mintclassTotals = 0;
        uint256 percentTotals = 0;
        
        uint256 nftroll = 0;
        uint256[] memory lootableNFT = new uint256[](3);

        lootableNFT[0] = _nftid1;
        lootableNFT[1] = _nftid2;
        lootableNFT[2] = _nftid3;
        
        for (uint256 x = 0; x < lootableNFT.length; ++x) {

            if (teazepacks.getNFTExists(lootableNFT[x])) {

                LootboxNFTids[lootboxid].push(lootableNFT[x]);

                mintclassTotals = mintclassTotals.add(teazepacks.getNFTClass(lootableNFT[nftroll]));
                percentTotals = percentTotals.add(teazepacks.getNFTPercent(lootableNFT[nftroll]));

            } else {
                require(teazepacks.getNFTExists(lootableNFT[x]), "E30");
            }            
            
        }                  

        uint256 boxroll = inserter.getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(block.timestamp)))%100), lootboxdogMax); //get box roll 0-89
        boxroll = boxroll+lootboxdogNormalizer; //normalize

        LootboxInfo storage lootboxinfo = lootboxInfo[lootboxid];

        lootboxinfo.rollNumber = boxroll;
        lootboxinfo.mintclassTotal = mintclassTotals;
        lootboxinfo.percentTotal = percentTotals;
        lootboxinfo.rewardAmount = _rewardAmt;
        lootboxinfo.timeend = block.timestamp.add(mintclassTotals.mul(timeEnder.mul(timeEndingFactor)).div(100));
        lootboxinfo.claimedBy = address(0);
        lootboxinfo.claimed = false;
            

        //update heldAmount
        heldAmount = heldAmount.add(_rewardAmt);

        payable(this).transfer(_rewardAmt);

        unclaimedBoxes.increment();

        activelootboxarray.push(lootboxid); //add lootboxid to loopable array for view function

    }

    function changeContracts(address _packsContract, address _inserter, address _nftcontract) external onlyOwner {
        packsContract = _packsContract;
        teazepacks = ITeazePacks(_packsContract);
        inserter = Inserter(_inserter);
        nftContract = _nftcontract;
        nft = ITeazeNFT(_nftcontract);
    }

}

