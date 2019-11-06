/****************************************************************************
* Copyright 2019, Optimizely, Inc. and contributors                        *
*                                                                          *
* Licensed under the Apache License, Version 2.0 (the "License");          *
* you may not use this file except in compliance with the License.         *
* You may obtain a copy of the License at                                  *
*                                                                          *
*    http://www.apache.org/licenses/LICENSE-2.0                            *
*                                                                          *
* Unless required by applicable law or agreed to in writing, software      *
* distributed under the License is distributed on an "AS IS" BASIS,        *
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. *
* See the License for the specific language governing permissions and      *
* limitations under the License.                                           *
***************************************************************************/

import XCTest

class BatchEventBuilderTests: XCTestCase {
    
    let datafileName = "feature_experiments"
    let featureExperimentKey = "feature_targeted_exp"
    let eventWithNoExperimentKey = "unused_event"
    let userId = "userId"
    var optimizely: OptimizelyClient?
    
    override func setUp() {
        optimizely = OptimizelyClient(sdkKey: "", periodicDownloadInterval: 0)
        
        let datafile = OTUtils.loadJSONDatafile(datafileName)
        XCTAssertNoThrow(try optimizely?.start(datafile: datafile!))
    }

    override func tearDown() {
        optimizely = nil
    }

    func testConversionEventWithNoExperiment() {
        let userContext = UserContext(config: optimizely!.config!,
                                      userId: userId,
                                      attributes: ["anyattribute": "value", "broswer_type": "firefox"])
        let conversion = ConversionEvent(userContext: userContext,
                                         eventKey: eventWithNoExperimentKey,
                                         tags: nil)
        
        XCTAssertNotNil(conversion?.batchEvent)
        
        XCTAssert(conversion?.batchEvent.enrichDecisions == true)
        
    }

    func testImpressionEventWithNoExperiment() {
        let experiment = optimizely?.config?.project.experiments.filter({$0.key == featureExperimentKey}).first
        let variation = experiment?.variations[0]
        
        let userContext = UserContext(config: optimizely!.config!,
                                      userId: userId,
                                      attributes: ["customattr": "yes"])
        
        let impression = ImpressionEvent(userContext: userContext,
                                         layerId: experiment!.layerId,
                                         experimentKey: experiment!.key,
                                         experimentId: experiment!.id,
                                         variationKey: variation!.key,
                                         variationId: variation!.id)
        
        XCTAssertNotNil(impression.batchEvent)

        XCTAssert(impression.batchEvent.enrichDecisions == true)
        
        XCTAssert(impression.batchEvent.visitors[0].attributes[0].key == "customattr")
        //XCTAssert(batchEvent?.visitors[0].attributes[0].value == .string)
    }

}
