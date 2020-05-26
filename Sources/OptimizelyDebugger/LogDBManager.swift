/****************************************************************************
* Copyright 2020, Optimizely, Inc. and contributors                        *
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
    
#if os(iOS) && (DEBUG || OPT_DBG)

import Foundation
import CoreData

/// Log message data stored in the session log database
final class LogItem: NSManagedObject {
    @NSManaged public var date: Date?
    @NSManaged public var level: Int16
    @NSManaged public var module: String?
    @NSManaged public var text: String?
}

/// This manages log messages stored into database during the current session.
class LogDBManager {
    
    // MARK: - props
    
    let maxItemsCount: Int
    private var itemsCount = AtomicProperty<Int>(property: 0)

    struct FetchSession {
        var level: OptimizelyLogLevel
        var keyword: String?
        var nextPage: Int = 0
        let countPerPage = 30
        
        var fetchOffset: Int {
            return countPerPage * nextPage
        }
        var fetchLimit: Int {
            return countPerPage
        }
        
        var lastFetchCount: Int = 0
        
        var direction: Direction = .forward {
            didSet {
                switch direction {
                case .forward:
                    nextPage += 1
                case .backward:
                    nextPage = nextPage > 0 ? (nextPage - 1) : 0
                case .reset:
                    nextPage = 0
                default:
                    break
                }
            }
        }
        
        init(level: OptimizelyLogLevel, keyword: String? = nil) {
            self.level = level
            self.keyword = keyword
        }
        
        /// Restart from the first page if level or keyward is changed
        /// - Parameters:
        ///   - level: new level
        ///   - keyword: new keyword
        mutating func reSyncIfNeeded(level: OptimizelyLogLevel, keyword: String? = nil) {
            if level != self.level || keyword != self.keyword {
                self.level = level
                self.keyword = keyword
                self.direction = .reset
            }
        }
        
    }
    
    enum Direction {
        case forward
        case backward
        case current
        case reset
    }
    
    var session: FetchSession?
    
    // MARK: - Thread-safe CoreData

    lazy var persistentContainer: NSPersistentContainer? = {
        let container = NSPersistentContainer(name: "OptimizelyLogModel",
                                              managedObjectModel: generateObjectModel())
        container.loadPersistentStores(completionHandler: { (_, error) in
            if let error = error as NSError? {
                print("[ERROR] Unresolved error \(error), \(error.userInfo)")
            }
        })
        
        let storeDescription = NSPersistentStoreDescription()
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [storeDescription]
        
        return container
    }()
    
    lazy var defaultContext: NSManagedObjectContext? = {
        if Thread.isMainThread {
            return self.persistentContainer?.viewContext
        } else {
            return self.persistentContainer?.newBackgroundContext()
        }
    }()
    
    // MARK: - init
    
    init(maxItemsCount: Int) {
        self.maxItemsCount = maxItemsCount
    }
    
    // MARK: - methods
    
    func saveContext () {
        guard let context = defaultContext else { return }

        context.perform {   // thread-safe
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    let nserror = error as NSError
                    print("Unresolved error \(nserror), \(nserror.userInfo)")
                }
            }
        }
    }
    
    // NOTE: we do not need to modify "LogItem"(NSManagedObject) which usually auto-generated by xcode
    //       but here we manually generate 2 files (LogItem+CoreDataClass.swift, LogItem+CoreDataProperties)
    //       for supporting package managers (SPM/CocoaPods/Carthage), which all have limitation for
    //       auto-generating those files.

    func insert(level: OptimizelyLogLevel, module: String, text: String) {
        guard let context = defaultContext else { return }

        context.perform {
            
            // count sync (session logs can be written in multiple contexts)
            
            self.itemsCount.performAtomic { (value) in
                var count = value
                if count >= self.maxItemsCount {
                    let numToBeRemoved = Int(Double(self.maxItemsCount) * 0.2)
                    if let countAfter = self.removeOldestItems(count: numToBeRemoved) {
                        count = countAfter
                    }
                }
                
                self.itemsCount.property = count + 1
            }
            
            // add log item
            
            let entity = NSEntityDescription.entity(forEntityName: "LogItem", in: context)!
            let logItem = NSManagedObject(entity: entity, insertInto: context)
            
            logItem.setValue(level.rawValue, forKey: "level")
            logItem.setValue(module, forKey: "module")
            logItem.setValue(text, forKey: "text")
            logItem.setValue(Date(), forKey: "date")
            
            self.saveContext()
        }
    }
    
    /// Asynchronously read log items from the session log database
    /// - Parameters:
    ///   - level: maximum log level to be included
    ///   - keyword: search keyword
    ///   - countPerPage: the number of items to be read at a time
    ///   - completion: a handler to be called in the main thread after completion
    func asyncRead(level: OptimizelyLogLevel,
                   keyword: String?,
                   direction: Direction = .forward,
                   completion: @escaping ([LogItem]) -> Void) {
        DispatchQueue.global().async {
            let items = self.read(level: level, keyword: keyword, direction: direction)
            DispatchQueue.main.async {
                completion(items)
            }
        }
    }
    
    /// Asynchronously remove all log items from the session log database
    /// - Parameter completion: a handler to be called in the main thread after completion
    func asyncClear(completion: @escaping () -> Void) {
        DispatchQueue.global().async {
            self.clear()
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    // MARK: - private methods

    private func read(level: OptimizelyLogLevel, keyword: String?, direction: Direction) -> [LogItem] {
        if session == nil {
            session = FetchSession(level: level, keyword: keyword)
        } else {
            session!.reSyncIfNeeded(level: level, keyword: keyword)
        }
        session!.direction = direction

        let items = fetchDB(session: session!)
        
        return items
    }
    
    private func clear() {
        guard let context = defaultContext else { return }

        context.performAndWait { // synchronous clear
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "LogItem")
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            
            do {
                try context.execute(deleteRequest)
                try context.save()
                
                session = nil
            } catch {
                print("[ERROR] log clear failed: \(error)")
            }
        }
    }
    
    private func removeOldestItems(count: Int) -> Int? {
        var updatedCount: Int?

        guard let context = defaultContext else { return updatedCount }

        context.performAndWait { // synchronous clear
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: "LogItem")
            let sort = NSSortDescriptor(key: "date", ascending: true)   // old date first
            request.sortDescriptors = [sort]
            
            
//            var subpredicates = [NSPredicate]()
//            subpredicates.append(NSPredicate(format: "level <= %d", session.level.rawValue))
//            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
//
            
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: request)
            
            do {
                try context.execute(deleteRequest)
                try context.save()
                
                // get accurate count after removing some items
                updatedCount = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "LogItem"))
            } catch {
                print("[ERROR] log clear failed: \(error)")
            }
        }
        
        return updatedCount
    }
    
    private func fetchDB(session: FetchSession) -> [LogItem] {
        guard let context = defaultContext else { return [] }

        var items = [LogItem]()
        
        context.performAndWait {  // synchronous fetch
            let request = NSFetchRequest<NSManagedObject>(entityName: "LogItem")
            request.fetchLimit = session.fetchLimit
            request.fetchOffset = session.fetchOffset
            
            let sort = NSSortDescriptor(key: "date", ascending: false)  // new date first
            request.sortDescriptors = [sort]
            var subpredicates = [NSPredicate]()
            subpredicates.append(NSPredicate(format: "level <= %d", session.level.rawValue))
            if let kw = session.keyword {
                subpredicates.append(NSPredicate(format: "text CONTAINS[cd] %@", kw))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
            
            if let fetched = try? context.fetch(request) as? [LogItem] {
                items = fetched
            } else {
                print("[ERROR] Failed to read log DB)")
                items = []
            }
        }
        
        return items
    }
    
}

extension LogDBManager {
    
    func generateObjectModel() -> NSManagedObjectModel {
        
         // Manual model creation (replacing .xcdatamodeld)
         // - Swift Package Manager(SPM) does not support CoreData resource file,
         //   therefore the object model (LogItem) is manually coded here.
         
         let logItem = NSEntityDescription()
         logItem.name = "LogItem"
         logItem.managedObjectClassName = NSStringFromClass(LogItem.self)
         
         let date = NSAttributeDescription()
         date.name = "date"
         date.attributeType = .dateAttributeType
         date.isOptional = true
        
         let level = NSAttributeDescription()
         level.name = "level"
         level.attributeType = .integer16AttributeType
         level.isOptional = false
         
         let module = NSAttributeDescription()
         module.name = "module"
         module.attributeType = .stringAttributeType
         module.isOptional = true

         let text = NSAttributeDescription()
         text.name = "text"
         text.attributeType = .stringAttributeType
         text.isOptional = true

         logItem.properties = [date, level, module, text]
         
         let model = NSManagedObjectModel()
         model.entities = [logItem]
         
        return model
    }
    
}

#endif