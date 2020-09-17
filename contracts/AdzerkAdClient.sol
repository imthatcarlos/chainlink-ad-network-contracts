pragma solidity 0.6.6;

import "@chainlink/contracts/src/v0.6/ChainlinkClient.sol";
import "@chainlink/contracts/src/v0.6/interfaces/LinkTokenInterface.sol";
import '@openzeppelin/contracts/access/Ownable.sol';
import "./IMobilityCampaigns.sol";

/**
 * @title AdzerkAdClient creates an ad campaigns from a given ad server API
 */
contract AdzerkAdClient is ChainlinkClient, Ownable {
  struct AdRequest {
    address creator;
    string campaignName;
    uint budgetETH;
  }

  address public oracleAddress;
  address public linkTokenAddress;
  IMobilityCampaigns public mobilityCampaigns;

  mapping(address => bool) public advertisers;
  mapping(address => uint) public advertisersPaymentsLINK;
  mapping(bytes32 => AdRequest) public adRequests;

  modifier onlyAdvertiser() {
    require(advertisers[msg.sender], 'AdzerkAdClient::onlyAdvertiser::msg.sender must have requested an ad import');
    _;
  }

  /**
   * @notice Deploy the contract with a specified address for the LINK
   * and Oracle contract addresses
   * @dev Sets the storage for the specified addresses
   * @param _link The address of the LINK token contract
   */
  constructor(address _link, address _oracle, address _campaignsContractAddress) public {
    oracleAddress = _oracle;
    mobilityCampaigns = IMobilityCampaigns(_campaignsContractAddress);

    if (_link == address(0)) {
      setPublicChainlinkToken();
      linkTokenAddress = 0xC89bD4E1632D3A43CB03AAAd5262cbe4038Bc571; // ChainlinkClient::LINK_TOKEN_POINTER
    } else {
      setChainlinkToken(_link);
      linkTokenAddress = _link;
    }
  }

  function setOracleAddress(address _oracle) external onlyOwner {
    require(_oracle != address(0), 'AdzerkAdClient::setOracleAddress::_oracle cannot be 0 address');
    oracleAddress = _oracle;
  }

  /**
   * @notice Returns the address of the LINK token
   * @dev This is the public implementation for chainlinkTokenAddress, which is
   * an internal method of the ChainlinkClient contract
   */
  function getChainlinkToken() public view returns (address) {
    return chainlinkTokenAddress();
  }

  /*
   * Allows an advertisers to import ads from their custom ad server
   * NOTE: the address must have already approved the transfer of LINK with linkToken.approve()
   * @param _jobId The bytes32 JobID to be executed
   * @param _paymentLINK The payment in LINK for the request
   * @param _apiURL The ad server URL to request data from
   * @param _apiToken The ad server api auth token
   * @param _pathCampaignName The dot-delimited path of top-level campaign name (response.data.campaign_name)
   * @param _pathCampaignAdCount The number of ad creatives under the given campaign path (response.data.ads.length)
   * @param _pathCampaignAdImage The dot-delimited path of ad creative images (response.data.ads[0].image_url)
   */
  function importAds(
    bytes32 _jobId,
    uint256 _paymentLINK,
    uint8 _pathCampaignAdCount,
    string memory _apiURL,
    string memory _campaignName,
    string memory _pathCampaignAdImage
  )
    public
    payable
    returns (bytes32[] memory requestIds)
  {
    advertisersPaymentsLINK[msg.sender] = _paymentLINK;

    // transfer required LINK tokens to this contract
    require(LinkTokenInterface(linkTokenAddress).transferFrom(msg.sender, address(this), _paymentLINK));

    // assert budget
    require(msg.value > 0, 'AdzerkAdClient::importAds::msg.value must be greater than 0');

    // split LINK evenly between requests
    uint256 amountperAdLINK = _paymentLINK / _pathCampaignAdCount;
    uint256 amountperAdETH = msg.value / _pathCampaignAdCount;

    requestIds = new bytes32[](_pathCampaignAdCount);
    for (uint8 i = 0; i < _pathCampaignAdCount; i++) {
      Chainlink.Request memory req = buildChainlinkRequest(_jobId, address(this), this.fulfillImportAds.selector);

      req.add("get", _apiURL);
      // req.add("headers", "{\'X-Adzerk-ApiKey\':\'_apiToken\'}");
      string[] memory path = new string[](2);
      path[0] = "foo"; // @TODO: trying to access object at array index
      path[1] = _pathCampaignAdImage;
      req.addStringArray("path", path);

      bytes32 requestId = sendChainlinkRequestTo(oracleAddress, req, amountperAdLINK);

      adRequests[requestId] = AdRequest({
        creator: msg.sender,
        campaignName: _campaignName,
        budgetETH: amountperAdETH
      });

      requestIds[i] = requestId;
    }

    return requestIds;
  }

  /**
   * @notice The fulfill method from requests created by this contract
   * @dev The recordChainlinkFulfillment protects this function from being called
   * by anyone other than the oracle address that the request was sent to
   * @param _requestId The ID that was generated for the request
   * @param _data The answer provided by the oracle
   */
  function fulfillImportAds(bytes32 _requestId, string memory _data)
    public
    recordChainlinkFulfillment(_requestId)
  {
    AdRequest memory request = adRequests[_requestId];

    mobilityCampaigns.createCampaignImported(
      request.creator,
      request.campaignName,
      _data
    );
  }

  /**
   * @notice Allows the owner to withdraw any LINK balance on the contract
   */
  function withdrawLink() public onlyAdvertiser {
    LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
    require(link.transfer(msg.sender, advertisersPaymentsLINK[msg.sender]), "AdzerkAdClient::withdrawLink::Unable to transfer");
  }

  /**
   * @notice Call this method if no response is received within 5 minutes
   * @param _requestId The ID that was generated for the request to cancel
   * @param _payment The payment specified for the request to cancel
   * @param _callbackFunctionId The bytes4 callback function ID specified for
   * the request to cancel
   * @param _expiration The expiration generated for the request to cancel
   */
  function cancelRequest(
    bytes32 _requestId,
    uint256 _payment,
    bytes4 _callbackFunctionId,
    uint256 _expiration
  )
    public
    onlyAdvertiser
  {
    require(adRequests[_requestId].creator == msg.sender, 'AdzerkAdClient::cancelRequest::only request creator');
    cancelChainlinkRequest(_requestId, _payment, _callbackFunctionId, _expiration);
  }
}
