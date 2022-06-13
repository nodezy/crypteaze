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

interface ITeazeNFT {
    function tokenURI(uint256 tokenId) external view returns (string memory); 
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function mint(address _recipient, string memory _uri, uint _packNFTid) external returns (uint256); 
}

interface Inserter {
    function makeActive() external; 
    function getNonce() external view returns (uint256);
    function getRandMod(uint256 _extNonce, uint256 _modifier, uint256 _modulous) external view returns (uint256);
}

interface ISimpCrates {
    function checkIfLootbox() external;
}

contract TeazePacks is Ownable, Authorizable, Whitelisted, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    Counters.Counter public _PackIds; //so we can track which Packs have been added to the system
    Counters.Counter public _NFTIds; //so we can track which NFT's have been added to the Packs
    Counters.Counter public _LootBoxIds; //so we can track amount of lootboxes in creation
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
        uint256 timeend; //amount of time pack exists before it expires
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

    mapping (string => bool) private collections; //Whether the collection name exists or not.
    mapping (string => bool) private nftnames; //Whether the collection name exists or not.
    mapping (uint => bool) private packs; //Whether the packID exists or not.
    mapping(uint256 => PackInfo) public packInfo; // Info of each NFT artist/infuencer wallet.
    mapping(uint256 => NFTInfo) public nftInfo; // Info of each NFT artist/infuencer wallet.
    
    uint256[] public activelootboxarray; //Array to store each active lootbox id so we can view.
    uint256[] private inactivelootboxarray; //Array to store each active lootbox id so we can view.
    mapping(uint => uint256[]) public PackNFTids; // array of NFT ID's listed under each pack.
    
    mapping (uint256 => bool) public claimed; //Whether the nft tokenID has been used to claim a lootbox or not.
    mapping(uint => uint256) public PackNFTmints; //number of NFT minted from a certain pack.
    mapping(address => mapping(uint => uint)) public userPackPurchased; //How many of each pack a certain address has minted.
    mapping(string => bool) private NFTuriExists;  // Get total # minted by URI.
    mapping(uint256 => uint) private NFTmintedCountID; // Get total # minted by NFTID.

    Inserter public inserter;
    ISimpCrates public simpcrates;
    address public nftContract; // Address of the associated farming contract.
    address public farmingContract; // Address of the associated farming contract.
    
    uint256 private randNonce;
    uint256 timeEnding = 2592000; //default pack lifetime of 30 days.
    
    constructor(address _nftContract, address _farmingContract, address _inserter, address _simpcrates) {
        nftContract = _nftContract;
        farmingContract = _farmingContract;
        simpcrates = ISimpCrates(_simpcrates);
        inserter = Inserter(_inserter);
        randNonce = inserter.getNonce();
        inserter.makeActive();
        addWhitelisted(owner());
    }

    receive() external payable {}

    function premint(address _recipient, uint256 _packid) public nonReentrant returns (uint256) {

        randNonce++;

        uint256 nftbalance = IERC721(nftContract).balanceOf(_recipient);
        if (_recipient != owner()) {
            require(nftbalance <= 100, "E01");
        }
        
        require(address(farmingContract) != address(0), "E02");
        require(msg.sender == address(farmingContract), "E03");

        PackInfo storage packinfo = packInfo[_packid];

        require(PackNFTmints[_packid] < packinfo.mintLimit, "E04");

        //Randomizing mint starts here
        uint packlength = PackNFTids[_packid].length;

        uint count = 0;

        //require(packlength >= 3, "E05");

        (,,uint256 percentTotal) = getAllNFTbyPack(_packid);

        require(percentTotal >= 100, "E29");

        uint256 roll = inserter.getRandMod(randNonce, _packid, percentTotal); //get user roll 0-99
        
        uint256[] memory array = new uint256[](percentTotal); //create array from 0-99

        for (uint256 x = 0; x < packlength; ++x) { //for each NFTID in the pack

            NFTInfo memory tempnftinfo = nftInfo[PackNFTids[_packid][x]]; //should be NFT info of each nft in for-loop

            for(uint256 y = 0; y < tempnftinfo.mintPercent; y++) {
                array[count] = PackNFTids[_packid][x]; //populate array with # of percentage (ex. 59%, put 59 entries in the array)
                count++;
            }

        }

        for (uint256 i = 0; i < array.length; i++) { //now we take our array and scramble the contents
            uint256 n = i + uint256(keccak256(abi.encodePacked(randNonce+i, _recipient))) % (array.length - i);
            uint256 temp = array[n];
            array[n] = array[i];
            array[i] = temp;
        }

        uint256 nftid = array[roll];
        NFTInfo storage nftinfo = nftInfo[nftid];
        
        //update counters

        NFTmintedCountID[nftid] = NFTmintedCountID[nftid] + 1;

        PackNFTmints[_packid] = PackNFTmints[_packid] + 1;

        simpcrates.checkIfLootbox();

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

    function setFarmingContract(address _address) public onlyAuthorized {
        farmingContract = _address;
    }

    function setCratesContract(address _address) public onlyAuthorized {
        simpcrates = ISimpCrates(_address);
    }

    function setPackInfo (string memory _collectionName, uint256 _price, uint256 _sbxprice, uint256 _priceStep, uint256 _mintLimit, uint256 _timeend, bool _redeemable, bool _purchasable) public onlyWhitelisted returns (uint256) {
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
        if (_timeend > 0) {packinfo.timeend = _timeend;} else {packinfo.timeend = block.timestamp.add(timeEnding);}
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
        require(!nftnames[_nftName], "E08");
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
            nftnames[_nftName] = true;

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
            ids[count] = PackNFTids[_packid][x];
            name[count] = nftinfo.nftName;
            percentTotal = percentTotal.add(nftinfo.mintPercent);
            count = count+1;
           
        }

        return (ids,name,percentTotal);
    }
    
    //Returns the name of all packs or collections
    function getAllCollectionNames() public view returns (uint256[] memory, string[] memory) {

        uint256 totalPacks = _PackIds.current();
        uint256[] memory ids = new uint256[](totalPacks);
        string[] memory name = new string[](totalPacks);
        uint256 count = 0;

        for (uint256 x = 1; x <= totalPacks; ++x) {

            PackInfo storage packinfo = packInfo[x];

            if (bytes(packinfo.collectionName).length > 0) {
                ids[count] = x;
                name[count] = packinfo.collectionName;
                count++;
            }

        }

        return (ids,name);
    }

    function deletePack(uint256 _packid) external onlyWhitelisted {// to do: add switch for packs to

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

        packinfocopy.packCreatorAddress = address(0);
        packinfocopy.collectionName = "";
        packinfocopy.packID = 0;
        packinfocopy.price = 0;
        packinfocopy.priceStep = 0;
        packinfocopy.sbxprice = 0;
        packinfocopy.mintLimit = 0;
        packinfocopy.redeemable = false;
        packinfocopy.purchasable = false;
        packinfocopy.exists = false;    

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
    function deleteNFT(uint256 _nftid) external onlyWhitelisted returns (bool complete) {

        NFTInfo storage nftinfo = nftInfo[_nftid];
        NFTInfo storage nftinfocopy = nftInfo[_NFTIds.current()];

        require(nftinfo.nftCreatorAddress == address(_msgSender()) || authorized[_msgSender()], "Sender is not creator or authorized");  

           NFTuriExists[nftinfo.uri] = false;
           nftnames[nftinfo.nftName] = false;

           uint packfromlength = PackNFTids[nftinfo.packID].length;

           for (uint256 x = 0; x < packfromlength; ++x) {   

               if (PackNFTids[nftinfo.packID][x] == _nftid) {

                   if(x == packfromlength-1) { //last in array, pop

                   PackNFTids[nftinfo.packID].pop();

                    nftinfo.nftCreatorAddress = address(0);
                    nftinfo.nftName = "";
                    nftinfo.uri = "";
                    nftinfo.packID = 0;
                    nftinfo.mintClass = 0;
                    nftinfo.mintPercent = 0;
                    nftinfo.lootboxable = false;
                    nftinfo.exists = false;

                    _NFTIds.decrement();     

                    return true;

                   } else { //copy last in array to this, then pop last

                   PackNFTids[nftinfo.packID][x] = PackNFTids[nftinfo.packID][packfromlength-1]; 
                   PackNFTids[nftinfo.packID].pop(); 

                    nftinfo.nftCreatorAddress = nftinfocopy.nftCreatorAddress;
                    nftinfo.nftName = nftinfocopy.nftName;
                    nftinfo.uri = nftinfocopy.uri;
                    nftinfo.packID = nftinfocopy.packID;
                    nftinfo.mintClass = nftinfocopy.mintClass;
                    nftinfo.mintPercent = nftinfocopy.mintPercent;
                    nftinfo.lootboxable = nftinfocopy.lootboxable;
                    nftinfo.exists = true;

                    nftinfocopy.nftCreatorAddress = address(0);
                    nftinfocopy.nftName = "";
                    nftinfocopy.uri = "";
                    nftinfocopy.packID = 0;
                    nftinfocopy.mintClass = 0;
                    nftinfocopy.mintPercent = 0;
                    nftinfocopy.lootboxable = false;
                    nftinfocopy.exists = false;

                    return true;

                   }

               }

           }                
       
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

        require(msg.sender == address(farmingContract), "E20");

        userPackPurchased[_recipient][_packid] = userPackPurchased[_recipient][_packid] + 1;
    }

    
    // Set cost of opening a pack
    function setPackPrice(uint256 _packid, uint256 _price, uint _priceStep, uint256 _sbxprice) public onlyAuthorized {

         require(packs[_packid], "E14");

        PackInfo storage packinfo = packInfo[_packid];

        require(_price > 0, "E09");
        require(_sbxprice > 0, "E10");

       packinfo.price = _price;
       packinfo.priceStep = _priceStep;
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


    function mintedCountbyID(uint256 _id) public view returns (uint256) {
        return NFTmintedCountID[_id];
    }

    function getNFTClass(uint256 _nftid) public view returns (uint256) {
         NFTInfo storage nftinfo = nftInfo[_nftid];
        return (nftinfo.mintClass);
    }

    function getNFTPercent(uint256 _nftid) public view returns (uint256) {
         NFTInfo storage nftinfo = nftInfo[_nftid];
        return (nftinfo.mintPercent);
    }

    function getLootboxAble(uint256 _nftid) public view returns (bool) {
        NFTInfo storage nftinfo = nftInfo[_nftid];
        return nftinfo.lootboxable;
    }

    function getNFTExists(uint256 _nftid) public view returns (bool) {
         NFTInfo storage nftinfo = nftInfo[_nftid];
        return (nftinfo.exists);
    }

    function getPackTimelimitFarm(uint256 _packid) public view returns (bool isLive) {
        bool live = false;

        PackInfo storage packinfo = packInfo[_packid];
        if (packinfo.timeend < block.timestamp) {
            live = true;
            return live;
        }


    }
    
    function getPackTimelimitCrates(uint256 _nftid) public view returns (bool isLive) {
        bool live = false;
        NFTInfo storage nftinfo = nftInfo[_nftid];

        PackInfo storage packinfo = packInfo[nftinfo.packID];
        if (packinfo.timeend < block.timestamp) {
            live = true;
            return live;
        }


    }
    

}

