//Contract based on https://docs.openzeppelin.com/contracts/3.x/erc721
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function mint(address _recipient, string memory _uri, uint _packNFTid) external returns (uint256); 
}


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

// Allows authorized users to add creators addresses to the whitelist
contract Whitelisted is Ownable, Authorizable {

    mapping(address => bool) public whitelisted;

    modifier onlyWhitelisted() {
        require(whitelisted[_msgSender()] || authorized[_msgSender()] || owner() == address(_msgSender()));
        _;
    }

    function addWhitelisted(address _toAdd) onlyAuthorized public {
        require(_toAdd != address(0));
        whitelisted[_toAdd] = true;
    }

    function removeWhitelisted(address _toRemove) onlyAuthorized public {
        require(_toRemove != address(0));
        require(_toRemove != address(_msgSender()));
        whitelisted[_toRemove] = false;
    }

}

contract TeazePacks is Ownable, Authorizable, Whitelisted, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter private _PackIds; //so we can track which Packs have been added to the system
    Counters.Counter private _NFTIds; //so we can track which NFT's have been added to the Packs
    Counters.Counter private _LootBoxIds; //so we can track amount of lootboxes in creation
    Counters.Counter public unclaimedBoxes; //so we can limit the amount of active unclaimed lootboxes
    Counters.Counter public claimedBoxes; //so we can track the total amount of claimed lootboxes

    struct PackInfo { //creator, name, id, price, priceStep, sbxprice, mintLimit, reedeemable, purchasable, exists
        address packCreatorAddress; //wallet address of the Pack creator
        string collectionName; // Name of nft creator/influencer/artist
        uint256 packID; //ID of the pack
        uint256 price; //BNB minting price of the NFT Pack
        uint256 priceStep; //how much the price of the NFT should increase in BNB
        uint256 sbxprice; //SimpBux price of minting from the NFT Pack
        uint256 mintLimit; //total amount of this NFT to mint
        bool redeemable; //can be purchased with SimpBux
        bool purchasable; //can be purchased with BNB tokens
        bool exists;
    }

    struct NFTInfo {
        address nftCreatorAddress; //wallet address of the Pack creator
        string nftName; // Name of the actual NFT artwork
        string uri; //address of NFT metadata
        uint256 packID; //ID of the 3 card pack
        uint256 mintClass; //0 = common, 1 = uncommon, 2 = rare
        uint256 mintPercent; //percent chance out of 100 for the NFT to mint
        bool lootboxable; //can be added to lootbox
        bool exists;
    }

    struct LootboxInfo {
        uint256 rollNumber; //number needed to claim reward
        uint256 rewardAmount; //amount of BNB in lootbox
        uint256 collectionArray; //array of NFT id's needed to claim
        uint256 percentTotal; //total percent of combined NFT mintPercent
        uint256 mintclassTotal; //total mintclass (higher mintclass = higher bnb reward)
        address claimedBy; //address that unlocked the lootbox
        bool claimed; //unclaimed = false, claimed = true
    }

    mapping (string => bool) private collections; //Whether the collection name exists or not.
    mapping (uint => bool) private packs; //Whether the packID exists or not.
    mapping(uint256 => PackInfo) public packInfo; // Info of each NFT artist/infuencer wallet.
    mapping(uint256 => NFTInfo) public nftInfo; // Info of each NFT artist/infuencer wallet.
    mapping(uint256 => LootboxInfo) public lootboxInfo; // Info of each lootbox.
    uint256[] public activelootboxarray; //Array to store each active lootbox id so we can view.
    uint256[] private inactivelootboxarray; //Array to store each active lootbox id so we can view.
    mapping(uint => uint256[]) private PackNFTids; // array of NFT ID's listed under each pack.
    mapping(uint256 => uint256[]) private LootboxNFTids; // array of NFT ID's listed under each lootbox.
    mapping (uint256 => bool) private claimed; //Whether the nft tokenID has been used to claim a lootbox or not.
    mapping(uint => uint256) private PackNFTmints; //number of NFT minted from a certain pack.
    mapping(address => mapping(uint => uint)) private userPackPurchased; //How many of each pack a certain address has minted.
     mapping(string => bool) private NFTuriExists;  // Get total # minted by URI.
     mapping(uint256 => uint) private NFTmintedCountID; // Get total # minted by NFTID.

    address public nftContract; // Address of the associated farming contract.
    address public farmingContract; // Address of the associated farming contract.
    uint256 private heldAmount = 0; //Variable to determine how much BNB is in the contract not allocated to a lootbox
    uint256 public maxRewardAmount = 300000000000000006; //Maximum reward of a lootbox (simpcrate)
    uint256 public rewardPerClass = 33333333333333334; //Amount each class # adds to reward (maxRewardAmount / nftPerLootBox)
    uint public nftPerLootbox = 3;
    uint public lootboxdogMax = 90; //Maximum roll the lootbox will require to unlock it
    uint256 public rollFee = 0.001 ether; //Fee the contract takes for each attempt at opening the lootbox once the user has the NFTs
    uint256 public unclaimedLimiter = 30; //Sets total number of unclaimed lootboxes that can be active at any given time

    constructor(address _nftContract) {
        nftContract = _nftContract;
    }

    receive() external payable {}

    function premint(address _recipient, uint256 _packid) public nonReentrant returns (uint256) {

        uint256 nftbalance = IERC721(nftContract).balanceOf(_recipient);
        require(nftbalance <= 100, "E01");

        require(address(farmingContract) != address(0), "E02");
        require(msg.sender == address(farmingContract), "E03");

        PackInfo storage packinfo = packInfo[_packid];

        require(PackNFTmints[_packid] < packinfo.mintLimit, "E04");

        //Randomizing mint starts here
        uint packlength = PackNFTids[_packid].length;

        require(packlength >= 3, "E05");

        uint256 roll = uint256(blockhash(block.number-1)) % 100; //get user roll 0-99
        
        uint256[] memory array = new uint256[](100); //create array from 0-99

        for (uint256 x = 0; x < packlength; ++x) { //for each NFTID in the pack

            NFTInfo memory tempnftinfo = nftInfo[PackNFTids[_packid][x]]; //should be NFT info of each nft in for loop

            for(uint256 y = 0; y < tempnftinfo.mintPercent; y++) {
                array[y] = PackNFTids[_packid][x]; //populate array with # of percentage (ex. 59%, put 59 entries in the array)
            }

        }

        for (uint256 i = 0; i < array.length; i++) { //now we take our array and scramble the contents
            uint256 n = i + uint256(keccak256(abi.encodePacked(block.timestamp))) % (array.length - i);
            uint256 temp = array[n];
            array[n] = array[i];
            array[i] = temp;
        }

        uint256 nftid = array[roll];
        NFTInfo storage nftinfo = nftInfo[nftid];
        
        //update counters

        NFTmintedCountID[nftid] = NFTmintedCountID[nftid] + 1;

        PackNFTmints[_packid] = PackNFTmints[_packid] + 1;

        if (unclaimedBoxes.current() <= unclaimedLimiter) {checkIfLootbox();}

        return ITeazeNFT(nftContract).mint(_recipient, nftinfo.uri, nftid);

    }

       //returns the balance of the erc20 token required for validation
    function checkBalance(address _token, address _holder) public view returns (uint256) {
        IERC20 token = IERC20(_token);
        return token.balanceOf(_holder);
    }
    
    function setNFTContract(address _address) public onlyAuthorized {
        nftContract = _address;
    }

    function setPackInfo (string memory _collectionName, uint256 _price, uint256 _sbxprice, uint256 _priceStep, uint256 _mintLimit, bool _redeemable, bool _purchasable) public onlyWhitelisted returns (uint256) {
        require(whitelisted[_msgSender()], "E06"); 
        require(bytes(_collectionName).length > 0, "E07");
        require(!collections[_collectionName], "E08");
        if(_purchasable) {require(_price > 0, "E09");}
        if(_redeemable) {require(_sbxprice > 0, "E10");}       
        require(_priceStep >= 0, "E11");
        require(_mintLimit > 0, "E12");
                
        _PackIds.increment();

        uint256 _packid = _PackIds.current();

        PackInfo storage packinfo = packInfo[_packid];
        
        packinfo.packCreatorAddress = _msgSender();
        packinfo.collectionName = _collectionName;
        packinfo.packID = _packid;
        packinfo.price = _price;
        packinfo.sbxprice = _sbxprice;
        packinfo.priceStep = _priceStep;
        packinfo.mintLimit = _mintLimit;
        packinfo.redeemable = _redeemable; //whether pack can be opened with SBX
        packinfo.purchasable = _purchasable; //whether the pack can be opened with BNB
        packinfo.exists = true;

        packs[_packid] = true;
        collections[_collectionName] = true;
        
        return _packid;
    }

    
    //NFT's get added to a pack # along with mint class (for the lootbox ordering) and mint percentages (for the user mint chance)
    function setNFTInfo(string memory _nftName, string memory _URI, uint256 _packID, uint256 _mintPercent, bool _lootboxable) public onlyWhitelisted returns (uint256) {

        require(whitelisted[_msgSender()], "E06"); 
        require(bytes(_nftName).length > 0, "E07");
        require(bytes(_URI).length > 0, "E13");
        require(_packID > 0, "E14");
        require(packs[_packID], "E14");
        require(_mintPercent > 0, "E15");
        require(!NFTuriExists[_URI], "E16");

        (,,uint256 percentTotal) = getAllNFTbyPack(_packID);

        require(percentTotal.add(_mintPercent) <= 100,"E17");

        _NFTIds.increment();

        uint256 _nftid = _NFTIds.current();

        NFTInfo storage nftinfo = nftInfo[_nftid];

           nftinfo.nftCreatorAddress = _msgSender();
           nftinfo.nftName = _nftName;  
           nftinfo.uri = _URI;
           nftinfo.packID = _packID;
           if (_mintPercent < 25) { nftinfo.mintClass = 3;}
           if (_mintPercent >= 25 && _mintPercent < 50) { nftinfo.mintClass = 2;}
           if (_mintPercent >= 50 && _mintPercent <= 100) { nftinfo.mintClass = 1;}
           nftinfo.mintPercent = _mintPercent;
           nftinfo.lootboxable = _lootboxable; //Whether this NFT can be added to a lootbox
           nftinfo.exists = true;

            NFTuriExists[_URI] = true;

            //To Do: if this NFT is inserted into the wrong pack, provide function that deletes from current pack and adds to correct pack

            PackNFTids[_packID].push(_nftid);

        return  _nftid; 

    }

    // Get the current NFT counter
    function getCurrentNFTID() public view returns (uint256) {
        return _NFTIds.current();
    }

    // Get all NFT IDs added to a pack, and return the mint percentage total
    function getAllNFTbyPack(uint256 _packid) public view returns (uint256[] memory, string[] memory, uint256) {

        uint packlength = PackNFTids[_packid].length;

        uint256[] memory ids = new uint256[](packlength);
        string[] memory name = new string[](packlength);
        uint256 count = 0;
        uint256 percentTotal = 0;

        for (uint256 x = 0; x < packlength; ++x) {          

            NFTInfo storage nftinfo = nftInfo[PackNFTids[_packid][x]];
            count = count.add(1);
            ids[count] = x;
            name[count] = nftinfo.nftName;
            percentTotal = percentTotal.add(nftinfo.mintPercent);
           
        }

        return (ids,name,percentTotal);
    }
    
    //Returns the name of all packs or collections
    function getAllCollectionNames() public view returns (uint256[] memory, string[] memory) {

        uint256 totalPacks = _PackIds.current();
        uint256[] memory ids = new uint256[](totalPacks);
        string[] memory name = new string[](totalPacks);
        uint256 count = 0;

        for (uint256 x = 0; x < totalPacks; ++x) {

            PackInfo storage packinfo = packInfo[x];

            if (bytes(packinfo.collectionName).length > 0) {
                count = count.add(1);
                ids[count] = x;
                name[count] = packinfo.collectionName;
            }

        }

        return (ids,name);
    }

    function deletePack(uint256 _packid) external onlyWhitelisted {

        PackInfo storage packinfo = packInfo[_packid];
        PackInfo storage packinfocopy = packInfo[_PackIds.current()];

        require(packinfo.packCreatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  

        //creator, name, id, price, priceStep, sbxprice, mintLimit, reedeemable, purchaseable, exists  

        collections[packinfo.collectionName] = false;

        packinfo.packCreatorAddress = packinfocopy.packCreatorAddress;
        packinfo.collectionName = packinfocopy.collectionName;
        packinfo.packID = packinfocopy.packID;
        packinfo.price = packinfocopy.price;
        packinfo.priceStep = packinfocopy.priceStep;
        packinfo.sbxprice = packinfocopy.sbxprice;
        packinfo.mintLimit = packinfocopy.mintLimit;
        packinfo.redeemable = packinfocopy.redeemable;
        packinfo.purchasable = packinfocopy.purchasable;
        packinfo.exists = true;    

        packinfo.packCreatorAddress = address(0);
        packinfo.collectionName = "";
        packinfo.packID = 0;
        packinfo.price = 0;
        packinfo.priceStep = 0;
        packinfo.sbxprice = 0;
        packinfo.mintLimit = 0;
        packinfo.redeemable = false;
        packinfo.purchasable = false;
        packinfo.exists = false;    

        _PackIds.decrement();

        assignAllNFTtoPack(_packid,0,false);

    }

    function assignAllNFTtoPack(uint256 _packIDfrom, uint256 _packIDto, bool _lootboxable) internal returns (bool) {

        require(packs[_packIDfrom], "E18");
        require(packs[_packIDto], "E19");

        uint packfromlength = PackNFTids[_packIDfrom].length;

        for (uint256 x = 0; x < packfromlength; ++x) {          

            NFTInfo storage nftinfo = nftInfo[PackNFTids[_packIDfrom][x]];
            
            nftinfo.packID = _packIDto;
            nftinfo.lootboxable = _lootboxable;

            //remove all NFT in 'from' pack
            PackNFTids[_packIDfrom].pop();

            //add NFT to 'to' pack mapping, will be created if it doesn't exist
            PackNFTids[_packIDto].push(PackNFTids[_packIDfrom][x]);
           
        }

        return (true);
    }

    function reassignNFTtoPack(uint256 _nftid, uint256 _packIDfrom, uint256 _packIDto, bool _lootboxable) internal returns (bool) {

        require(packs[_packIDfrom], "E18");
        require(packs[_packIDto], "E19");

        uint packfromlength = PackNFTids[_packIDfrom].length;

        NFTInfo storage nftinfo = nftInfo[_nftid];

           for (uint256 x = 0; x < packfromlength; ++x) { //remove from old pack

               if (PackNFTids[nftinfo.packID][x] == _nftid) {

                   if(x == packfromlength-1) { //last in array, pop

                   PackNFTids[nftinfo.packID].pop();

                   } else { //copy last in array to this, then pop last

                   PackNFTids[nftinfo.packID][x] = PackNFTids[nftinfo.packID][packfromlength-1]; 
                   PackNFTids[nftinfo.packID].pop(); 

                   }

               }

           }

           nftinfo.packID = _packIDto; //add to new pack in NFT struct
           nftinfo.lootboxable = _lootboxable;
           PackNFTids[_packIDto].push(_nftid); //add NFT to pack struct

        return (true);
        
    }

    function assignAllNFTtoPackAuth(uint256 _packIDfrom, uint256 _packIDto, bool _lootboxable) external onlyAuthorized returns (bool) {
       return assignAllNFTtoPack(_packIDfrom,_packIDto,_lootboxable);
    }

    
    // Set creator address to new, or set to 0 address to clear out the NFT completely
    function deleteNFT(uint256 _nftid) public onlyWhitelisted {

        NFTInfo storage nftinfo = nftInfo[_nftid];
        NFTInfo storage nftinfocopy = nftInfo[_NFTIds.current()];

        require(nftinfo.nftCreatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  

           NFTuriExists[nftinfo.uri] = false;

           uint packfromlength = PackNFTids[nftinfo.packID].length;

           for (uint256 x = 0; x < packfromlength; ++x) {   

               if (PackNFTids[nftinfo.packID][x] == _nftid) {

                   if(x == packfromlength-1) { //last in array, pop

                   PackNFTids[nftinfo.packID].pop();

                   } else { //copy last in array to this, then pop last

                   PackNFTids[nftinfo.packID][x] = PackNFTids[nftinfo.packID][packfromlength-1]; 
                   PackNFTids[nftinfo.packID].pop(); 

                   }

               }

           }

           nftinfo.nftCreatorAddress = nftinfocopy.nftCreatorAddress;
           nftinfo.nftName = nftinfocopy.nftName;
           nftinfo.uri = nftinfocopy.uri;
           nftinfo.packID = nftinfocopy.packID;
           nftinfo.mintClass = nftinfocopy.mintClass;
           nftinfo.mintPercent = nftinfocopy.mintPercent;
           nftinfo.lootboxable = nftinfocopy.lootboxable;
           nftinfo.exists = true;

           nftinfo.nftCreatorAddress = address(0);
           nftinfo.nftName = "";
           nftinfo.uri = "";
           nftinfo.packID = 0;
           nftinfo.mintClass = 0;
           nftinfo.mintPercent = 0;
           nftinfo.lootboxable = false;
           nftinfo.exists = false;

           _NFTIds.decrement();          
       
    }

    // Set NFT name
    function setNFTName(uint256 _nftid, string memory _name) external onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(bytes(_name).length > 0, "E07");    

       nftinfo.nftName = _name;
    }

    // Get NFT URI string
    function getNFTURI(uint256 _nftid) public view returns (string memory) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.uri;
    }

    // Set NFT URI string
    function setNFTUri(uint256 _nftid, string memory _uri) external onlyAuthorized {

        NFTInfo storage nftinfo = nftInfo[_nftid];

        require(nftinfo.nftCreatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  
        require(bytes(_uri).length > 0, "E13");     
        require(!NFTuriExists[_uri], "E16"); 

        NFTuriExists[nftinfo.uri] = false;

       nftinfo.uri = _uri;

        NFTuriExists[_uri] = true;
    }
    

    // Get pack info
    function getPackInfo(uint256 _packid) public view returns (uint256,uint256,uint256,uint256,bool,bool) {
        PackInfo storage packinfo = packInfo[_packid];
        return (packinfo.price,packinfo.priceStep,packinfo.sbxprice,packinfo.mintLimit,packinfo.redeemable,packinfo.purchasable);

    }
    
    function packExists(uint256 _packid) external view returns (bool) {
        
        return packs[_packid];
    }

    function nftExists(uint256 _nftid) external view returns (bool) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.exists;
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

    function getIDbyURI(string memory _uri) public view returns (uint256) {
        uint256 totalNFT = _NFTIds.current();
        uint256 nftID = 0;

        for (uint256 x = 1; x <= totalNFT; ++x) {

            NFTInfo storage nftinfo = nftInfo[x];

            if (keccak256(bytes(nftinfo.uri)) == keccak256(bytes(_uri))) {   
                nftID = x;
            }

        }

        return nftID;
    }

    function getPackIDbyNFT(uint256 _nftid) external view returns (uint256) {

        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.packID;

    }

    function packPurchased(address _recipient, uint256 _packid) external {

        require(msg.sender == address(nftContract), "E20");

        userPackPurchased[_recipient][_packid] = userPackPurchased[_recipient][_packid] + 1;
    }

    
    // Set cost of opening a pack
    function setPackPrice(uint256 _packid, uint256 _price, uint256 _sbxprice) public onlyAuthorized {

         require(packs[_packid], "E14");

        PackInfo storage packinfo = packInfo[_packid];

        require(_price > 0, "E09");
        require(_sbxprice > 0, "E10");

       packinfo.price = _price;
       packinfo.sbxprice = _sbxprice;
    }

    

    // Set NFT redeemable with SimpBux
    function setPackRedeemable(uint256 _packid, bool _redeemable) public onlyAuthorized {

         require(packs[_packid], "E14");

        PackInfo storage packinfo = packInfo[_packid];

       packinfo.redeemable = _redeemable;
    }

    

    // Set Pack purchasable with BNB tokens
    function setPackPurchasable(uint256 _packid, bool _purchasable) public onlyAuthorized {

        require(packs[_packid], "E14");

        PackInfo storage packinfo = packInfo[_packid];

       packinfo.purchasable = _purchasable;
    }

    

    // Set Pack mint limit
    function setPackMintLimit(uint256 _packid, uint256 _limit) public onlyAuthorized {

        require(packs[_packid], "E14");

        PackInfo storage packinfo = packInfo[_packid];

        require(_limit > 0, "E12");

       packinfo.mintLimit = _limit;
    }


    function getPackTotalMints(uint256 _packid) external view returns (uint256) {
        return PackNFTmints[_packid];
    }

    function getUserPackPurchased(address _recipient, uint256 _packid) public view returns (uint256) {
        return userPackPurchased[_recipient][_packid];
    }

    function getUserPackPrice(address _recipient, uint256 _packid) external view returns (uint256) {

        uint256 purchases = getUserPackPurchased(_recipient, _packid);

        (uint256 price,uint256 priceStep,,,,) = getPackInfo(_packid);
             
        uint256 userPrice = price.add(purchases.mul(priceStep));

        return userPrice;
    }

    function checkIfLootbox() internal {
        uint256 previousBalance = address(this).balance;

        if (previousBalance.sub(heldAmount) >= maxRewardAmount) {
            //create lootbox

            _LootBoxIds.increment();

            uint256 lootboxid = _LootBoxIds.current();

            LootboxInfo storage lootboxinfo = lootboxInfo[lootboxid];

            uint256 packids = _PackIds.current();
            uint256 mintclassTotals = 0;
            uint256 percentTotals = 0;

            for (uint256 x = 0; x < nftPerLootbox; ++x) {

                uint256 packroll = uint256(blockhash(block.number-1)) % packids-1; //get a random pack
                packroll = packroll.add(1); //normalize

                uint packnftlength = PackNFTids[packroll].length;

                for (uint256 y = 0; y < packnftlength; ++y) {

                        uint256 nftroll = uint256(blockhash(block.number-1)) % packnftlength-1; //get a random nft
    
                    LootboxNFTids[lootboxid].push(PackNFTids[packroll][nftroll]);

                    NFTInfo storage nftinfo = nftInfo[PackNFTids[packroll][nftroll]];

                    mintclassTotals = mintclassTotals.add(nftinfo.mintClass);
                    percentTotals = percentTotals.add(nftinfo.mintPercent);

                }

            }

            uint256 boxreward = rewardPerClass.mul(mintclassTotals);

            uint256 boxroll = uint256(blockhash(block.number-1)) % lootboxdogMax; //get box roll 0-89
            boxroll = boxroll.add(1); //normalize

            lootboxinfo.rollNumber = boxroll;
            lootboxinfo.collectionArray = lootboxid;
            lootboxinfo.mintclassTotal = mintclassTotals;
            lootboxinfo.percentTotal = percentTotals;
            lootboxinfo.rewardAmount = boxreward;
            lootboxinfo.claimedBy = address(0);
            lootboxinfo.claimed = false;
            

            //update heldAmount
            heldAmount = heldAmount.add(boxreward);

            unclaimedBoxes.increment();

            activelootboxarray.push(packids); //add packid to loopable array for view function
            
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
            NFTunusedresult = NFTunusedresult || claimed[tokentemp];
        }

        if (hasNFTresult && !NFTunusedresult) { //user has all NFT, none have been used to obtain SimpCrate, roll to beat the dog
            userroll = uint256(blockhash(block.number-1)) % 99; 
            userroll = userroll.add(1);

            if (userroll > lootboxinfo.rollNumber) {
                //transfer winnings to user, update struct, mark tokenIDs as ineligible for future lootboxes
                payable(_msgSender()).transfer(lootboxinfo.rewardAmount);
                heldAmount = heldAmount.sub(lootboxinfo.rewardAmount);

                for (uint256 z=0; z<tokens.length; z++) {
                    claimed[tokens[z]] = true;
                }

                lootboxinfo.claimed = true;
                lootboxinfo.claimedBy = _msgSender();

                claimedBoxes.increment();
                unclaimedBoxes.decrement();

            }
        }

        payable(this).transfer(rollFee);

        uint arraylength = activelootboxarray.length;

        //Remove packid from active array
        for(uint x = 0; x < arraylength; x++) {
            if (activelootboxarray[x] == _lootboxid) {
                activelootboxarray[x] = activelootboxarray[arraylength-1];
                activelootboxarray.pop();
            }
        }       

        //Add packid to inactive array
        inactivelootboxarray.push(_lootboxid);

        return (hasNFTresult, NFTunusedresult, userroll, lootboxinfo.rollNumber);

    }   

    function checkWalletforNFT(uint256 _position, address _holder, uint256 _lootbox) public view returns (bool nftpresent, uint256 tokenid) {

        uint256 nftbalance = IERC721(nftContract).balanceOf(_holder);
        bool result;
        uint256 token;

         for (uint256 y = 0; y < nftbalance; y++) {

             string memory boxuri = getNFTURI(LootboxNFTids[_lootbox][_position]);
             string memory holderuri = ITeazeNFT(nftContract).tokenURI(ITeazeNFT(nftContract).tokenOfOwnerByIndex(_holder, y));

            if (keccak256(bytes(boxuri)) == keccak256(bytes(holderuri))) {
                result = true;
                token = ITeazeNFT(nftContract).tokenOfOwnerByIndex(_holder, y);
            } else {
                result = false;
                token = 0;
            }

        }

        return (result, tokenid);
    }

    function checkIfWinnwer(uint256 _lootboxid) external view returns (bool) {

        LootboxInfo storage lootboxinfo = lootboxInfo[_lootboxid];

        //check wallet against Simpcrate NFT

        uint256 lootboxlength = LootboxNFTids[_lootboxid].length;

        bool result = false;
        bool hasNFTresult = true;
        bool NFTunusedresult = false;
        uint256 tokentemp;

        for (uint x = 0; x < lootboxlength; x++) {

            (result,tokentemp) = checkWalletforNFT(x,_msgSender(), _lootboxid);
            hasNFTresult = hasNFTresult && result;
            NFTunusedresult = NFTunusedresult || claimed[tokentemp];
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
        require(_dogroll >= 50, "E25");
        require(_dogroll <= 90, "E26");

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
}

