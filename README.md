# AlfredHomework

####  整體功能處裡流程為：
* 驗證相簿權限 (為了後續檔案寫入系統相片庫)
* 讀取 bundle 中的 mp4 檔案 
* 透過 AVAssetReader 依序抽出 frame 資料
* 資料經過 ObjectDetection 分類為 person後啟動 AVAssetWriter 的寫入
* 啟動寫入後的 frame 如果分類有 person 就透過圖像處理為人像加框，沒有則直接寫入
* 啟動寫入後先戳記第一筆 timeStemp，以便後續的 frame 資料時間戳如大於十秒需關閉寫入
* 每次有 person 分類的 frame 讀取都進行 debounceTime的累加，因此超過 debounceTimeConstant 秒數都沒有 person 分類的 frame 讀取到的話，也直接關閉寫入。
* AVAssetWriter 寫入完成後，reset 相關參數，透過 PHPhotoLibrary 將影片檔案寫入系統相片庫，並透過 FileManager 刪掉 Documents 中原檔。
* 繼續讀取 frame 等待下次 person 分類 frame 的觸發。

#### 備註：

* person 分類的 confidence 設定要大於 0.9 是因為測試影片中有些畫面雖然不是人像，卻被 ObjectDetection 認定為 person，可能導致錯誤的錄影觸發時機，此為物件特徵辨識的問題，但為了 Demo 方便，這邊濾掉 confidence 低於 0.9 的判斷，讓 Demo 功能的呈現更明顯 (實際使用 confidence 可能需要經過多次實驗調整)。 
* 無辨識到 person 後五秒關閉寫入，目前測試影片可能不明顯(跟10秒關檔條件容易重疊)，因此如果要方便測試更明顯無偵測到 person 後關檔的功能，可修改 debounceTimeConstant 數值 (2 or 3) ，便不會與10秒關檔條件重疊。
