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
    function getNFTIDwithToken(uint256 _tokenid) external view returns (uint256);
}

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function getUserTokenIDtoNFTID(address _holder, uint _tokenID) external view returns (uint256);
}

interface IDirectory {
    function getInserter() external view returns (address);
    function getNFT() external view returns (address);
    function getPacks() external view returns (address);
}

contract SimpCrates is Ownable, Authorizable, ReentrancyGuard {
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

    IDirectory public directory;

    uint256 public heldAmount; //Variable to determine how much BNB is in the contract not allocated to a lootbox
    uint256 public maxRewardAmount = 240000000000000012; //Maximum reward of a lootbox (simpcrate)
    uint256 public rewardPerClass = 13333333333333334; //Amount each class # adds to reward (maxRewardAmount / nftPerLootBox)
    uint256 public nftPerLootbox = 3;
    uint256 public rewardDivisor = 6;
    uint256 public lootboxdogMax = 59; //Maximum roll the lootbox will require to unlock it
    uint256 public lootboxdogNormalizer = 31;
    uint256 private randNonce;
    uint256 public rollFee = 0.002 ether; //Fee the contract takes for each attempt at opening the lootbox once the user has the NFTs
    uint256 public gasRefund = 0.0035 ether; //Amount to refund user who triggers the creation of a simpcrate
    uint256 public unclaimedLimiter = 30; //Sets total number of unclaimed lootboxes that can be active at any given time
    uint256 timeEnder = 86400; //time multiplier for when lootboxes end, based on mintclass (defautl 1 week)
    uint256 timeEndingFactor = 234; //will be multiplied by timeEnder and mintClass to get dynamic lifetimes on crates based on difficulty
    bool public boxesEnabled = true;

    event ClaimResult(bool isWinner, bool indexed hasAllNFT, uint indexed userRoll, uint indexed dogRoll, bool isExpired);

    constructor(address _directory) {
        directory = IDirectory(_directory);
        randNonce = Inserter(directory.getInserter()).getNonce();
        Inserter(directory.getInserter()).makeActive();
        addAuthorized(owner());
    }

    receive() external payable {}

    //returns the balance of the erc20 token required for validation
    function checkBalance(address _token, address _holder) public view returns (uint256) {
        IERC20 token = IERC20(_token);
        return token.balanceOf(_holder);
    }
    
    function rescueETHFromContract() external onlyOwner {
        address payable _owner = payable(_msgSender());
        _owner.transfer(address(this).balance);
    }

    function transferERC20Tokens(address _tokenAddr, address _to, uint _amount) external onlyOwner {
       
        IERC20(_tokenAddr).transfer(_to, _amount);
    }


    function checkIfLootbox(address _checker) external nonReentrant {

         address packs = directory.getPacks();

        require(msg.sender == address(packs), "Sender is not packs contract");

        uint256 _nftids = ITeazePacks(packs).getCurrentNFTID();
        
        if (address(this).balance.add(gasRefund) >= heldAmount.add(maxRewardAmount) && _nftids >=3) {

            //get 'lootboxable' NFT
            
            uint256 count; 
            uint256 countmore;           

            for (uint x=1;x<=_nftids;x++) { //first time get all NFT that are live and lootable
                if (ITeazePacks(packs).getLootboxAble(x) && ITeazePacks(packs).getPackTimelimitCrates(x)) {
                    count++;
                }
            }

            uint256[] memory lootableNFT = new uint256[](count); //Now create the correct sized memory array

            for (uint x=1;x<=_nftids;x++) { //Now populate array with the correct NFT so its packed correctly (no zeros)
                if (ITeazePacks(packs).getLootboxAble(x) && ITeazePacks(packs).getPackTimelimitCrates(x)) {
                    lootableNFT[countmore]=x;
                    countmore++;
                }
            }

            uint lootableNFTcount = lootableNFT.length;

            if (lootableNFTcount >= 3) {

                //create lootbox

                randNonce++;

                _LootBoxIds.increment();

                uint256 lootboxid = _LootBoxIds.current();

                uint256 mintclassTotals;
                uint256 percentTotals;
                
                uint256 nftroll;
                
                
                for (uint256 x = 1; x <= nftPerLootbox; x++) {

                    nftroll = Inserter(directory.getInserter()).getRandMod(randNonce, x, lootableNFTcount.mul(100)); //get a random nft
                    nftroll = nftroll+100;
                    nftroll = nftroll.div(100);
                    nftroll = nftroll-1;

                    LootboxNFTids[lootboxid].push(lootableNFT[nftroll]);

                    mintclassTotals += ITeazePacks(packs).getNFTClass(lootableNFT[nftroll]);
                    percentTotals += ITeazePacks(packs).getNFTPercent(lootableNFT[nftroll]);

                    //now remove that nft from the array so we dont get duplicates in the lootbox 
                    if(lootableNFT[nftroll] == lootableNFT[lootableNFTcount-1]) { //if last in array, make zero and decrement lootable array

                        lootableNFT[nftroll] = 0;
                        lootableNFTcount-=1;

                    } else { //copy last array value to rolled array value, make last array value zero, decrement lootable count

                        lootableNFT[nftroll] = lootableNFT[lootableNFTcount-1];
                        lootableNFT[lootableNFTcount-1] = 0;
                        lootableNFTcount-=1;
                    }
                                        
                }                  

                uint256 boxreward = rewardPerClass.mul(mintclassTotals);

                uint256 boxroll = Inserter(directory.getInserter()).getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(block.timestamp)))%100), lootboxdogMax); //get box roll 0-89
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

                payable(_checker).transfer(gasRefund);

            }
                    
        }
    }

    function ClaimLootbox(uint256 _lootboxid) external payable nonReentrant returns (bool isWinner,  bool hasNFTs, uint256 roll, uint256 dogroll, bool isretired) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        require(!lootboxinfo.claimed, "E21");
        require(msg.value == rollFee, "E22");

        uint256 lootboxlength = LootboxNFTids[_lootboxid].length;

        bool result = false;
        bool hasNFTresult = true;
        bool winner = false;
        bool isRetired = false;
        uint256[] memory tokens = new uint256[](lootboxlength); //create array 
        uint256 tokentemp;
        uint256 userroll = 0;
        uint256 lootbox = _lootboxid; 

        userroll = Inserter(directory.getInserter()).getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(_msgSender())))%100), 100); 
        userroll = userroll+1;

        if (userroll >= lootboxinfo.rollNumber) {

            for (uint x = 0; x < lootboxlength; x++) { //check wallet against Simpcrate NFT

                (result,tokentemp) = checkWalletforNFT(x,_msgSender(), lootbox);
                tokens[x] = tokentemp;
                hasNFTresult = hasNFTresult && result;
            }

            if (hasNFTresult) { //user has all NFT, none have been used to obtain SimpCrate, roll to beat the dog

                //transfer winnings to user, update struct, mark tokenIDs as ineligible for future lootboxes
                winner = true;
                payable(_msgSender()).transfer(lootboxinfo.rewardAmount);
                heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);

                for (uint256 z=0; z<tokens.length; z++) {
                    claimedNFT[tokens[z]] = true;
                }

                lootboxinfo.claimed = true;
                lootboxinfo.claimedBy = _msgSender();
                
                retireLootbox(lootbox);

            } else {
                require(hasNFTresult, "E87");
            }

        } else {

            //put logic here to retire if lootbox is expired and put lootbox reward back into pool for a new one
            if (block.timestamp > lootboxinfo.timeend) {

                heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);
                retireLootboxExpired(lootbox);
                isRetired = true;
            }

        }

        payable(this).transfer(rollFee);

        emit ClaimResult(winner, hasNFTresult, userroll, lootboxinfo.rollNumber, isRetired);

        return (winner, hasNFTresult, userroll, lootboxinfo.rollNumber, isRetired);

    }   

    function checkWalletforDuplicate(address _holder, uint256 _nftid) public view returns (bool nftpresent, uint256 tokenid) {

        address nft = directory.getNFT();
        uint256 nftbalance = IERC721(nft).balanceOf(_holder);

       
        for (uint256 y = 0; y < nftbalance; y++) {

            uint usertokenid = ITeazeNFT(nft).tokenOfOwnerByIndex(_holder, y);

            if(_nftid == ITeazeNFT(nft).getUserTokenIDtoNFTID(_holder,usertokenid)) {
              
                if(!claimedNFT[usertokenid]) {
                    return (true, usertokenid);
                } 
                
            } 

        }

        return (false, 0);
    }

   function checkWalletforNFT(uint256 _position, address _holder, uint256 _lootbox) public view returns (bool nftpresent, uint256 tokenid) {

        address nft = directory.getNFT();
        uint256 nftbalance = IERC721(nft).balanceOf(_holder);

       
        for (uint256 y = 0; y < nftbalance; y++) {

            uint usertokenid = ITeazeNFT(nft).tokenOfOwnerByIndex(_holder, y);

            if(LootboxNFTids[_lootbox][_position] == ITeazeNFT(nft).getUserTokenIDtoNFTID(_holder,usertokenid)) {
              
                if(!claimedNFT[usertokenid]) {
                    return (true, usertokenid);
                } 
                
            } 

        }

        return (false, 0);
    }

    function checkIfHasAllNFT(uint256 _lootboxid, address _holder) external view returns (bool) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        //check wallet against Simpcrate NFT

        uint256 lootboxlength = LootboxNFTids[_lootboxid].length;

        bool result = false;
        bool hasNFTresult = true;

        for (uint x = 0; x < lootboxlength; x++) {

            (result,) = checkWalletforNFT(x, _holder, _lootboxid);
            hasNFTresult = hasNFTresult && result;
        }

        if ((lootboxinfo.claimed == false) && hasNFTresult) {return true;} else {return false;}       

    }

    function updateRewardAmounts(uint256 _maxRewardAmount, bool _auth) external onlyAuthorized {

        //the larger the _maxRewardAmount the longer it will take the contract to create a lootbox
        //the more _nftPerLootbox the harder they will be to open, taking longer for users to collect the appropriate NFTs

        //we can set some limitations here or override them with _auth = true

        if (!_auth) {
            require(_maxRewardAmount < 0.5 ether, "E23");
            
        }

        maxRewardAmount = _maxRewardAmount;
        
        rewardPerClass = maxRewardAmount.div(rewardDivisor);

    }

    function updateNFTperLootbox(uint _nftPerLootbox, bool _auth) external onlyAuthorized {

         if (!_auth) {
           require(_nftPerLootbox <= 5, "E24");            
        }   

        nftPerLootbox = _nftPerLootbox;
    }

     function updateRewardDivisor(uint _divisor) external onlyAuthorized {

         rewardDivisor = _divisor;
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

    function getActiveSimpCratesLength() external view returns (uint256) {
        return activelootboxarray.length;
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

    function retireLootbox(uint256 _lootboxid) internal { //change to internal for production
        uint arraylength = activelootboxarray.length;

        //Remove lootboxid from active array
        for(uint x = 0; x < arraylength; x++) {
            if (activelootboxarray[x] == _lootboxid) {
                activelootboxarray[x] = activelootboxarray[arraylength-1];
                activelootboxarray.pop();

                //Add lootboxid to inactive array
                inactivelootboxarray.push(_lootboxid);

                claimedBoxes.increment();

                 if(unclaimedBoxes.current() > 0) {
                    unclaimedBoxes.decrement();
                }

                return;
            }
        }       

    }

    function retireLootboxExpired(uint256 _lootboxid) internal {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

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

    function createLootboxAdmin(uint256 _nftid1, uint256 _nftid2, uint256 _nftid3, uint256 _rewardAmt, uint256 _timeend) external payable onlyAuthorized {

        require(msg.value == _rewardAmt, "E31");

        address packs = directory.getPacks();

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

            if (ITeazePacks(packs).getNFTExists(lootableNFT[x])) {

                LootboxNFTids[lootboxid].push(lootableNFT[x]);

                mintclassTotals = mintclassTotals.add(ITeazePacks(packs).getNFTClass(lootableNFT[nftroll]));
                percentTotals = percentTotals.add(ITeazePacks(packs).getNFTPercent(lootableNFT[nftroll]));

            } else {
                require(ITeazePacks(packs).getNFTExists(lootableNFT[x]), "E30");
            }            
            
        }                  

        uint256 boxroll = Inserter(directory.getInserter()).getRandMod(randNonce, uint8(uint256(keccak256(abi.encodePacked(block.timestamp)))%100), lootboxdogMax); //get box roll 0-89
        boxroll = boxroll+lootboxdogNormalizer; //normalize

        LootboxInfo storage lootboxinfo = lootboxInfo[lootboxid];

        lootboxinfo.rollNumber = boxroll;
        lootboxinfo.mintclassTotal = mintclassTotals;
        lootboxinfo.percentTotal = percentTotals;
        lootboxinfo.rewardAmount = _rewardAmt;
        if(_timeend == 0) {
            lootboxinfo.timeend = block.timestamp.add(mintclassTotals.mul(timeEnder.mul(timeEndingFactor)).div(100));
        } else {
            lootboxinfo.timeend = _timeend;
        }
        
        lootboxinfo.claimedBy = address(0);
        lootboxinfo.claimed = false;
            

        //update heldAmount
        heldAmount = heldAmount.add(_rewardAmt);

        payable(this).transfer(_rewardAmt);

        unclaimedBoxes.increment();

        activelootboxarray.push(lootboxid); //add lootboxid to loopable array for view function

    }

    function changeDirectory(address _directory) external onlyAuthorized {
        directory = IDirectory(_directory);
    }

    function getCrateCreationAmt() external view returns(uint, uint, uint, uint) {
        return (heldAmount.add(maxRewardAmount),address(this).balance.add(gasRefund),gasRefund,maxRewardAmount);
    }

    function getLootboxNFTids(uint _lootbox) external view returns(uint256[] memory) {

        uint256 lootboxlength = LootboxNFTids[_lootbox].length;

        uint256[] memory lootableNFT = new uint256[](lootboxlength);

        for (uint256 x = 0; x < lootboxlength; ++x) {

           lootableNFT[x] = LootboxNFTids[_lootbox][x];
        
        }

        return lootableNFT;
    }

    function isCrateReady() external view returns (bool) {
        return (address(this).balance.add(gasRefund) >= heldAmount.add(maxRewardAmount));
    }

}

